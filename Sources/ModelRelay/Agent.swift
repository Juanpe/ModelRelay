import AnyLanguageModel
import Foundation
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
/// the calls to one API. Agents name it by `id`. A kit with a `server` gets
/// its tools from that server (an MCP server) when a step runs.
public struct ToolKit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var tools: [AgentTool]
    public var server: ToolServer?

    public init(id: String, name: String, summary: String = "", tools: [AgentTool], server: ToolServer? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tools = tools
        self.server = server
    }
}

/// Where a tool set's tools come from when a server (an MCP server) offers
/// them, rather than requests defined here.
public struct ToolServer: Codable, Sendable, Hashable {
    public var url: String
    /// Sent with every call. Values may use `{{secret.NAME}}`.
    public var headers: [HTTPRequest.Header]
    /// The person signs in to the server (OAuth); the app keeps the tokens.
    public var signsIn: Bool

    public init(url: String, headers: [HTTPRequest.Header] = [], signsIn: Bool = false) {
        self.url = url
        self.headers = headers
        self.signsIn = signsIn
    }
}

/// A tool a server offers, as it describes itself.
public struct ServerTool: Codable, Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String
    public var parameters: [Field]
    /// Parameters the tool can't do without.
    public var required: [String]
    /// Unless the server marks a tool read-only, it may change something,
    /// and needs the same permission as a write request.
    public var changesSomething: Bool

    public init(
        name: String,
        title: String? = nil,
        description: String,
        parameters: [Field] = [],
        required: [String] = [],
        changesSomething: Bool = true
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.parameters = parameters
        self.required = required
        self.changesSomething = changesSomething
    }
}

/// One open connection to a tool server.
public protocol ToolServerConnection: Sendable {
    func tools() async throws -> [ServerTool]
    func call(_ tool: String, arguments: [String: Value]) async throws -> Value
}

/// Opens connections to tool servers. ModelRelay has no network code of its
/// own: apps pass one (ModelRelayMCP connects to MCP servers).
public protocol ToolServerConnector: Sendable {
    func connect(to kit: ToolKit) async throws -> any ToolServerConnection
}

/// What request steps and agent tools need to make a call.
struct RequestContext: Sendable {
    var requests: (any RequestPerformer)?
    var secrets: (any SecretProvider)?
    var writePolicy: WritePolicy
    var timeout: Duration
    var policy: WorkflowExecutionPolicy = .unrestricted
    var control: ExecutionControl? = nil

    /// `trace`, when given, receives the request as sent, with secrets hidden.
    func perform(
        _ request: HTTPRequest,
        step: String,
        trace: StepTrace? = nil,
        toolName: String? = nil,
        onDispatch: (@Sendable () -> Void)? = nil,
        resolve: (String) -> Value?
    ) async throws -> Value {
        try Task.checkCancellation()
        try policy.checkNetwork(step: step)
        try policy.checkTool(changesSomething: request.method.isWrite, step: step)
        guard requests != nil else { throw RelayError.requestsUnavailable(step: step) }
        let templates = [request.url, request.body ?? ""] + request.headers.map(\.value)
        for ref in templates.flatMap({ Template.references(in: $0) }) where !ref.hasPrefix("secret.") {
            guard resolve(ref) != nil else { throw RelayError.unknownReference(ref, step: step) }
        }
        let name = toolName ?? step
        try control?.beginTool(name, step: step)
        do {
            let result = try await performBody(request, step: step, trace: trace, onDispatch: onDispatch, resolve: resolve)
            control?.emit(.toolCompleted, step: step, tool: name)
            return result
        } catch {
            control?.emit(.toolFailed, step: step, tool: name, category: failureCategory(error))
            throw error
        }
    }

    private func performBody(
        _ request: HTTPRequest,
        step: String,
        trace: StepTrace?,
        onDispatch: (@Sendable () -> Void)?,
        resolve: (String) -> Value?
    ) async throws -> Value {
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
            throw operationFailure(step: step, error: error, secrets: Array(values.values))
        }
        trace?.input = prepared.description
        if request.method.isWrite { try await authorize(prepared, step: step) }
        // One attempt only: a write that timed out may still have happened.
        do {
            let response = try await withTimeout(timeout) {
                onDispatch?()
                return try await requests.perform(prepared)
            }
            let result = try RequestBuilder.value(from: response, reading: request.reading)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the cause in memory; only the diagnostic is redacted.
            if case RelayError.limitExceeded = error { throw error }
            throw operationFailure(step: step, error: error, uncertain: request.method.isWrite, secrets: prepared.secrets)
        }
    }
}

extension RequestContext {
    /// Throws unless the write policy lets `prepared` (something that
    /// changes something) go ahead.
    func authorize(_ prepared: PreparedRequest, step: String) async throws {
        try policy.checkTool(changesSomething: true, step: step)
        let allowed = switch writePolicy {
        case .allow: true
        case .deny: false
        case let .ask(confirm): await confirm(prepared)
        }
        guard allowed else { throw RelayError.writeNotAllowed(step: step) }
    }
}

/// A server tool as an AnyLanguageModel `Tool`. Calls that may change
/// something ask the write policy first, like write requests.
struct ServerToolCall: Tool {
    let tool: ServerTool
    let kit: ToolKit
    let connection: any ToolServerConnection
    let step: String
    let context: RequestContext
    let log: ToolCallLog

    /// Chat APIs accept letters, digits, `_` and `-` in tool names.
    var name: String { Self.safeName(tool.name) }
    var description: String { tool.description.isEmpty ? (tool.title ?? tool.name) : tool.description }
    var parameters: GenerationSchema {
        (try? SchemaBuilder.object(named: name, fields: tool.parameters))
            ?? (try! GenerationSchema(root: DynamicGenerationSchema(name: name, properties: []), dependencies: []))
    }

    static func safeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(64))
    }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try Task.checkCancellation()
        try log.record(tool.name)
        try context.policy.checkNetwork(step: step)
        try context.policy.checkTool(changesSomething: tool.changesSomething, step: step)
        var values: [String: Value] = [:]
        if case let .dictionary(fields) = Value(arguments) { values = fields }
        try context.control?.beginTool(tool.name, step: step)
        var dispatched = false
        do {
            if tool.changesSomething {
                try await context.authorize(ServerCallDescription.prepared(kit: kit, tool: tool.name, arguments: values), step: step)
            }
            dispatched = true
            if tool.changesSomething { log.markWriteDispatched() }
            let text = try await connection.call(tool.name, arguments: values).jsonText
            context.control?.emit(.toolCompleted, step: step, tool: tool.name)
            return text.count > AgentTool.maxOutputCharacters ? String(text.prefix(AgentTool.maxOutputCharacters)) + "…" : text
        } catch {
            context.control?.emit(.toolFailed, step: step, tool: tool.name, category: failureCategory(error))
            if error is CancellationError { throw error }
            throw operationFailure(step: step, error: error, uncertain: dispatched && tool.changesSomething)
        }
    }
}

/// How a call to a server tool reads in a confirmation or a step's record.
enum ServerCallDescription {
    static func prepared(kit: ToolKit, tool: String, arguments: [String: Value]) -> PreparedRequest {
        let body = try? JSONSerialization.data(
            withJSONObject: ["tool": tool, "arguments": Value.dictionary(arguments).jsonObject],
            options: [.sortedKeys, .prettyPrinted]
        )
        return PreparedRequest(
            method: .post,
            url: URL(string: kit.server?.url ?? "") ?? URL(string: "about:blank")!,
            headers: [],
            body: body,
            secrets: []
        )
    }
}

/// Runs `work`, failing with `InvalidOutput` if it takes longer than `limit`.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    message: String? = nil,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw OperationTimeout(description: message ?? "No answer within \(limit)")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// The tools one agent step called, shared by its tools to enforce the limit.
final class ToolCallLog: Sendable {
    private struct State { var names: [String] = []; var active = true; var wrote = false }
    private let state = Mutex(State())
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var calls: [String] { state.withLock { $0.names } }
    var mayHaveWritten: Bool { state.withLock { $0.wrote } }
    func markWriteDispatched() { state.withLock { $0.wrote = true } }
    /// A backend retaining an old tool wrapper must not use it in a later step.
    func finish() { state.withLock { $0.active = false } }

    /// Records a call, or throws once the step has used all its calls.
    func record(_ name: String) throws {
        try state.withLock { state in
            guard state.active else { throw InvalidOutput(reason: "This step's tool access has ended") }
            guard state.names.count < limit else {
                throw InvalidOutput(reason: "The model called tools more than \(limit) times")
            }
            state.names.append(name)
        }
    }
}

/// An `AgentTool` as an AnyLanguageModel `Tool`.
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
        try Task.checkCancellation()
        try log.record(spec.name)
        let args = Value(arguments)
        let value = try await context.perform(spec.request, step: step, toolName: spec.name, onDispatch: {
            if spec.request.method.isWrite { log.markWriteDispatched() }
        }) { reference in
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
    package var jsonText: String {
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
        case let .text(text): try container.encode(text)
        case let .number(number): try container.encode(number)
        case let .bool(bool): try container.encode(bool)
        case let .list(items): try container.encode(items.map(JSONValue.init))
        case let .dictionary(fields): try container.encode(fields.mapValues(JSONValue.init))
        // A tool or a JSON body gets the words, never the picture's bytes.
        case let .image(image): try container.encode(image.text ?? "")
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
    if case let RelayError.stepFailed(_, reason) = error { return reason }
    if case let RelayError.operationFailed(_, failure) = error { return failure.info.message }
    if let error = error as? WorkflowValidationError { return "Invalid workflow: " + error.issues.map { "\($0.step): \($0.detail)" }.joined(separator: "; ") }
    if case let RelayError.policyViolation(_, reason) = error { return reason }
    if case let RelayError.invalidContext(_, reason) = error { return reason }
    if case RelayError.writeNotAllowed = error { return "it wanted to change something and wasn't allowed" }
    if case let RelayError.missingSecret(name, _) = error { return "the key \(name) is missing" }
    if case let RelayError.unknownModel(id) = error { return "the model “\(id.rawValue)” isn't available" }
    if case RelayError.missingModel = error { return "it has no model" }
    if case let RelayError.unknownReference(reference, _) = error { return "“\(reference)” isn't available here" }
    if case RelayError.requestsUnavailable = error { return "requests can't be made here" }
    // An app's own errors (a Keychain failure, say) explain themselves.
    if let described = (error as? any LocalizedError)?.errorDescription { return described }
    return String(describing: error)
}
