import Foundation
import FoundationModels
import Synchronization

/// What a cloud model call failed with. Never contains the API key.
public struct CloudModelError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var message: String
    public var description: String { status == 0 ? message : "HTTP \(status): \(message)" }
}

enum CloudHTTP {
    /// Tests swap in a session whose protocol answers locally.
    static let session = Mutex(URLSession(configuration: .ephemeral))

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = session.withLock { $0 }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            // Say which server didn't answer, not just "the network connection was lost".
            throw CloudModelError(status: 0, message: "Couldn't reach \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = object["error"] as? [String: Any]
            throw CloudModelError(status: status, message: error?["message"] as? String ?? "The server refused the request")
        }
        return object
    }
}

/// A conversation in the shape chat APIs take: system text, then turns that
/// are text, tool calls the model made, or what those tools returned.
struct ChatTurns {
    enum Turn {
        case user(String)
        case assistant(String)
        case toolCalls([(id: String, name: String, arguments: String)])
        case toolResult(id: String, name: String, text: String)
    }

    var system: String
    var turns: [Turn]

    init(_ transcript: Transcript) {
        var system: [String] = []
        var turns: [Turn] = []
        // Tool outputs are matched to the call they answer: by id, or else the
        // oldest open call to the same tool.
        var open: [(id: String, name: String)] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions): system.append(Self.text(instructions.segments))
            case .prompt(let prompt): turns.append(.user(Self.text(prompt.segments)))
            case .response(let response): turns.append(.assistant(Self.text(response.segments)))
            case .toolCalls(let calls):
                let list = calls.map { (id: $0.id, name: $0.toolName, arguments: $0.arguments.jsonString) }
                open += list.map { (id: $0.id, name: $0.name) }
                turns.append(.toolCalls(list))
            case .toolOutput(let output):
                let index = open.firstIndex { $0.id == output.id } ?? open.firstIndex { $0.name == output.toolName }
                let id = index.map { open.remove(at: $0).id } ?? output.id
                turns.append(.toolResult(id: id, name: output.toolName, text: Self.text(output.segments)))
            default: break
            }
        }
        self.system = system.joined(separator: "\n\n")
        self.turns = turns
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil // Attachments aren't sent to text-only APIs.
            }
        }.joined(separator: "\n")
    }

    /// A tool's parameters as plain JSON Schema.
    static func parameters(_ tool: Transcript.ToolDefinition) -> [String: Any] {
        (try? CloudSchema(tool.parameters).json) ?? ["type": "object", "properties": [String: Any]()]
    }

    /// A model's tool call arguments (a JSON string or object) as an object.
    static func object(_ arguments: Any?) -> [String: Any] {
        if let object = arguments as? [String: Any] { return object }
        if let text = arguments as? String, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        return [:]
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A `GenerationSchema` as plain JSON Schema for a cloud API. APIs want an
/// object at the root, so anything else is wrapped in `{ "value": … }`.
struct CloudSchema {
    var name: String
    var json: [String: Any]
    var isWrapped: Bool

    init(_ schema: GenerationSchema) throws {
        let data = try JSONEncoder().encode(schema)
        var root = Self.clean(try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        name = (root["title"] as? String).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" } } ?? "Result"
        root["title"] = nil
        if root["type"] as? String == "object" {
            json = root
            isWrapped = false
        } else {
            json = ["type": "object", "properties": ["value": root], "required": ["value"], "additionalProperties": false]
            isWrapped = true
        }
        if name.isEmpty { name = "Result" }
    }

    /// The model's JSON, unwrapped if needed, as text the session parses.
    func content(from object: Any) throws -> String {
        var value = object
        if isWrapped, let dictionary = object as? [String: Any], let inner = dictionary["value"] { value = inner }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Drops keys strict JSON Schema validators reject.
    private static func clean(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary["x-order"] = nil
            for (key, nested) in dictionary { dictionary[key] = clean(nested) }
            return dictionary
        }
        if let array = value as? [Any] { return array.map(clean) }
        return value
    }
}
