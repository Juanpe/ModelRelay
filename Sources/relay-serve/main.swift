import Foundation
import ModelRelay
import ModelRelayMLX
import Network

// relay-serve: runs ModelRelay workflows over HTTP on 127.0.0.1.
//
//   relay-serve <workflows-dir> [--port 8787]
//
//   GET  /health                 → {"ok": true}
//   GET  /workflows              → names of the loaded workflows
//   POST /run/<name>             body: {"input": <string or JSON>, "model": "apple.on-device"?}
//                                → {"output": …, "steps": [{"step","model","fallback","ms"}], "ms": …}
//
// Workflows are `Workflow` JSON files (`<name>.json`). An optional "model"
// overrides every step's model for that request. Loopback only: nothing on the
// network can reach it, and it holds no keys.

struct Request: Decodable {
    let input: JSONValue
    let model: String?
}

/// Any JSON, so callers can send an article object or plain text.
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// Objects become pretty JSON text: the model reads them as data.
    var asInput: Value {
        if case .string(let text) = self { return .text(text) }
        let data = (try? JSONEncoder.sorted.encode(self)) ?? Data()
        return .text(String(decoding: data, as: UTF8.self))
    }

    init(_ value: Value) {
        switch value {
        case .null: self = .null
        case .text(let v): self = .string(v)
        case .number(let v): self = .number(v)
        case .bool(let v): self = .bool(v)
        case .list(let v): self = .array(v.map(JSONValue.init))
        case .dictionary(let v): self = .object(v.mapValues(JSONValue.init))
        }
    }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()
}

@Sendable func overriding(_ steps: [Step], model: ModelID) -> [Step] {
    steps.map { step in
        var step = step
        switch step.kind {
        case .ifEquals(let ref, let value, let then, let otherwise):
            step.kind = .ifEquals(reference: ref, value: value, then: overriding(then, model: model),
                                  otherwise: overriding(otherwise, model: model))
        case .parallel(let children):
            step.kind = .parallel(overriding(children, model: model))
        case .prompt, .extract, .classify:
            step.model = model
        case .template:
            break
        }
        return step
    }
}

// MARK: - Startup

var arguments = Array(CommandLine.arguments.dropFirst())
var port: UInt16 = 8787
if let i = arguments.firstIndex(of: "--port"), i + 1 < arguments.count {
    port = UInt16(arguments[i + 1]) ?? port
    arguments.removeSubrange(i...(i + 1))
}
guard let directory = arguments.first else {
    print("usage: relay-serve <workflows-dir> [--port 8787]")
    exit(2)
}

var workflows: [String: Workflow] = [:]
for file in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where file.hasSuffix(".json") {
    let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
    do {
        workflows[String(file.dropLast(5))] = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
    } catch {
        print("Skipping \(file): \(error)")
    }
}
let loaded = workflows
let listenPort = port
let runner = WorkflowRunner(catalog: ModelCatalog().registeringMLXModels())

// MARK: - HTTP

@Sendable func respond(_ connection: NWConnection, status: Int, json: some Encodable) {
    let body = (try? JSONEncoder.sorted.encode(json)) ?? Data("{}".utf8)
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
}

struct ErrorBody: Encodable { let error: String }
struct StepOut: Encodable { let step: String; let model: String?; let fallback: Bool; let skipped: Bool; let ms: Int }
struct RunOut: Encodable { let output: JSONValue; let steps: [StepOut]; let ms: Int }

@Sendable func milliseconds(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

@Sendable func handle(_ connection: NWConnection, request data: Data) {
    guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
        return respond(connection, status: 400, json: ErrorBody(error: "Malformed request"))
    }
    let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
    let body = data[split.upperBound...]
    let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
    guard parts.count >= 2 else { return respond(connection, status: 400, json: ErrorBody(error: "Malformed request")) }
    let method = parts[0], path = String(parts[1])

    switch (method, path) {
    case ("GET", "/health"):
        respond(connection, status: 200, json: ["ok": true])
    case ("GET", "/workflows"):
        respond(connection, status: 200, json: loaded.keys.sorted())
    case ("POST", let path) where path.hasPrefix("/run/"):
        let name = String(path.dropFirst(5))
        guard var workflow = loaded[name] else {
            return respond(connection, status: 404, json: ErrorBody(error: "No workflow named \(name)"))
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(body)) else {
            return respond(connection, status: 400, json: ErrorBody(error: #"Body must be {"input": …, "model": "…"?}"#))
        }
        if let model = request.model { workflow.steps = overriding(workflow.steps, model: ModelID(model)) }
        Task {
            do {
                let report = try await runner.run(workflow, input: request.input.asInput)
                let steps = report.records.map {
                    StepOut(step: $0.step, model: $0.model?.rawValue, fallback: $0.usedFallback, skipped: $0.skipped,
                            ms: milliseconds($0.duration))
                }
                respond(connection, status: 200, json: RunOut(output: JSONValue(report.output), steps: steps,
                                                              ms: milliseconds(report.duration)))
            } catch {
                respond(connection, status: 500, json: ErrorBody(error: String(describing: error)))
            }
        }
    default:
        respond(connection, status: 404, json: ErrorBody(error: "Unknown route \(method) \(path)"))
    }
}

/// Reads until the headers and the declared body length have arrived.
@Sendable func receive(_ connection: NWConnection, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, isComplete, error in
        var buffer = buffer
        if let chunk { buffer.append(chunk) }
        if let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).lowercased()
            let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if buffer.count - split.upperBound >= length || isComplete {
                return handle(connection, request: buffer)
            }
        }
        if isComplete || error != nil { connection.cancel(); return }
        receive(connection, buffer: buffer)
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listenPort)!)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in
    connection.start(queue: .global())
    receive(connection)
}
listener.stateUpdateHandler = { state in
    if case .ready = state { print("relay-serve on http://127.0.0.1:\(listenPort) · workflows: \(loaded.keys.sorted().joined(separator: ", "))") }
    if case .failed(let error) = state { print("Listener failed: \(error)"); exit(1) }
}
listener.start(queue: .main)
dispatchMain()
