import AnyLanguageModel
import Foundation

/// A server tool as an AnyLanguageModel `Tool`. Calls that may change
/// something ask the write policy first, like write requests. Host tool kits
/// use it too, as servers that don't reach the network.
struct ServerToolCall: Tool {
    let tool: ServerTool
    let kit: ToolKit
    let connection: any ToolServerConnection
    let reachesNetwork: Bool
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
        if reachesNetwork { try context.policy.checkNetwork(step: step) }
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
            // Host tool kits have no server: their calls read as `host:<kit id>`.
            url: URL(string: kit.server?.url ?? "host:\(kit.id)") ?? URL(string: "about:blank")!,
            headers: [],
            body: body,
            secrets: []
        )
    }
}
