import AnyLanguageModel
import Foundation

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
