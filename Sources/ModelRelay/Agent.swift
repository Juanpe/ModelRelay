import Foundation
import FoundationModels
import Synchronization

/// A tool an agent step may call: an HTTP request whose templates can read the
/// arguments the model chose as `{{args.NAME}}`, plus earlier results and
/// secrets like any request step.
public struct AgentTool: Codable, Sendable, Hashable {
    /// Small models can loop on tools; one agent step makes at most this many calls.
    public static let maxCallsPerStep = 6
    /// Tool output is trimmed to this many characters before the model reads it.
    static let maxOutputCharacters = 4000

    public var name: String
    public var description: String
    public var parameters: [Field]
    public var request: HTTPRequest

    public init(name: String, description: String, parameters: [Field] = [], request: HTTPRequest) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.request = request
    }
}

/// A set of tools defined once and shared by many agent steps, such as all
/// the calls to one API. Agents name it by `id`.
public struct ToolKit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var tools: [AgentTool]

    public init(id: String, name: String, summary: String = "", tools: [AgentTool]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tools = tools
    }
}

/// What request steps and agent tools need to make a call.
struct RequestContext: Sendable {
    var requests: (any RequestPerformer)?
    var secrets: (any SecretProvider)?
    var writePolicy: WritePolicy
    var timeout: Duration

    func perform(_ request: HTTPRequest, step: String, resolve: (String) -> Value?) async throws -> Value {
        guard let requests else { throw RelayError.requestsUnavailable(step: step) }
        var values: [String: String] = [:]
        for name in RequestBuilder.secretNames(in: request) {
            guard let value = try await secrets?.secret(named: name) else {
                throw RelayError.missingSecret(name, step: step)
            }
            values[name] = value
        }
        let prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.prepare(request, secrets: values, resolve: resolve)
        } catch {
            throw RelayError.stepFailed(step: step, reason: failureReason(error))
        }
        if request.method.isWrite {
            let allowed = switch writePolicy {
            case .allow: true
            case .deny: false
            case .ask(let confirm): await confirm(prepared)
            }
            guard allowed else { throw RelayError.writeNotAllowed(step: step) }
        }
        // One attempt only: a write that timed out may still have happened.
        do {
            let response = try await withTimeout(timeout) { try await requests.perform(prepared) }
            return try RequestBuilder.value(from: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RelayError.stepFailed(step: step, reason: failureReason(error))
        }
    }
}

/// Runs `work`, failing with `InvalidOutput` if it takes longer than `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw InvalidOutput(reason: "No answer within \(limit)")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// The tools one agent step called, shared by its tools to enforce the limit.
final class ToolCallLog: Sendable {
    private let names = Mutex<[String]>([])
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var calls: [String] { names.withLock { $0 } }

    /// Records a call, or throws once the step has used all its calls.
    func record(_ name: String) throws {
        try names.withLock { names in
            guard names.count < limit else {
                throw InvalidOutput(reason: "The model called tools more than \(limit) times")
            }
            names.append(name)
        }
    }
}

/// An `AgentTool` as a FoundationModels `Tool`.
struct RequestTool: Tool {
    let spec: AgentTool
    let step: String
    let context: RequestContext
    let log: ToolCallLog
    let resolve: @Sendable (String) -> Value?

    var name: String { spec.name }
    var description: String { spec.description }
    var parameters: GenerationSchema {
        (try? SchemaBuilder.object(named: spec.name, fields: spec.parameters))
            ?? (try! GenerationSchema(root: DynamicGenerationSchema(name: spec.name, properties: []), dependencies: []))
    }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try log.record(spec.name)
        let args = Value(arguments)
        let value = try await context.perform(spec.request, step: step) { reference in
            if reference.hasPrefix("args.") { return args[String(reference.dropFirst("args.".count))] }
            return resolve(reference)
        }
        let text = value.jsonText
        return text.count > AgentTool.maxOutputCharacters
            ? String(text.prefix(AgentTool.maxOutputCharacters)) + "…"
            : text
    }
}

extension Value {
    /// Compact JSON, which models read more reliably than `textValue` for nested data.
    var jsonText: String {
        guard let data = try? JSONEncoder().encode(JSONValue(self)),
              let text = String(data: data, encoding: .utf8) else { return textValue }
        return text
    }
}

/// Encodes a `Value` as plain JSON (not the tagged enum form).
private struct JSONValue: Encodable {
    let value: Value
    init(_ value: Value) { self.value = value }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .list(let items): try container.encode(items.map(JSONValue.init))
        case .dictionary(let fields): try container.encode(fields.mapValues(JSONValue.init))
        }
    }
}

/// A short, readable reason for a failed step: the request's own message for a
/// failed tool ("getWeather: The server answered HTTP 503"), never a dump of
/// the tool's internals.
func failureReason(_ error: any Error) -> String {
    if let toolError = error as? LanguageModelSession.ToolCallError {
        return "\(toolError.tool.name): \(failureReason(toolError.underlyingError))"
    }
    if case RelayError.stepFailed(_, let reason) = error { return reason }
    if case RelayError.writeNotAllowed = error { return "it wanted to change something and wasn't allowed" }
    if case RelayError.missingSecret(let name, _) = error { return "the key \(name) is missing" }
    return String(describing: error)
}
