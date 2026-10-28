import Foundation

extension WorkflowExecutor {
    func runToolStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        let context: RequestContext = execution.context
        let trace: StepTrace = execution.trace
        guard case let .useTool(kitID, toolName, arguments) = step.kind else { throw InvalidOutput(reason: "Expected a tool step") }

        guard let kit = toolKits[kitID] else {
            throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(kitID)” isn't available")
        }
        let rendered = arguments.mapValues { Template.render($0, scope.resolve) }
        let value: Value
        if kit.server != nil {
            let connection = try await connect(kit, step: step.name, policy: scope.policy)
            guard let tool = try await serverTools(kit, connection, step: step.name).first(where: { $0.name == toolName }) else {
                throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
            }
            let typed = ServerArguments.typed(rendered, for: tool)
            let call = ServerCallDescription.prepared(kit: kit, tool: tool.name, arguments: typed)
            trace.input = call.description
            try scope.policy.checkTool(changesSomething: tool.changesSomething, step: step.name)
            try scope.control.beginTool(tool.name, step: step.name)

            let invocation: ServerToolInvocation = .init(tool: tool, connection: connection, arguments: typed, request: call)
            value = try await callServerTool(invocation, execution: execution, control: scope.control)
        } else {
            guard let spec = kit.tools.first(where: { $0.name == toolName }) else {
                throw RelayError.stepFailed(step: step.name, reason: "\(kit.name) has no tool “\(toolName)”")
            }
            value = try await context.perform(spec.request, step: step.name, trace: trace, toolName: spec.name) { reference in
                if reference.hasPrefix("args.") { return rendered[String(reference.dropFirst("args.".count))].map(Value.text) }
                return scope.resolve(reference)
            }
        }
        scope.record(execution.record(value))
        return value
    }

    private func callServerTool(_ invocation: ServerToolInvocation, execution: WorkflowStepExecution, control: ExecutionControl) async throws -> Value {
        var dispatched: Bool = false

        do {
            if invocation.tool.changesSomething { try await execution.context.authorize(invocation.request, step: execution.step.name) }
            dispatched = true
            // One attempt only: a dispatched write may already have happened.
            let value: Value = try await withTimeout(stepTimeout) {
                try await invocation.connection.call(invocation.tool.name, arguments: invocation.arguments)
            }
            control.emit(.toolCompleted, step: execution.step.name, tool: invocation.tool.name)
            return value
        } catch is CancellationError {
            control.emit(.toolFailed, step: execution.step.name, tool: invocation.tool.name)
            throw CancellationError()
        } catch {
            control.emit(.toolFailed, step: execution.step.name, tool: invocation.tool.name, category: failureCategory(error))
            try rethrowExecutionControlError(error)
            throw operationFailure(step: execution.step.name, error: error, uncertain: dispatched && invocation.tool.changesSomething)
        }
    }

    /// Opens a connection to a tool set's server.
    func connect(_ kit: ToolKit, step: String, policy: WorkflowExecutionPolicy) async throws -> any ToolServerConnection {
        try policy.checkNetwork(step: step)
        try policy.checkTool(changesSomething: false, step: step)
        guard let toolServers else { throw RelayError.stepFailed(step: step, reason: "tool servers can't be reached here") }

        do {
            return try await withTimeout(stepTimeout) { try await toolServers.connect(to: kit) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw operationFailure(step: step, error: error)
        }
    }

    func serverTools(_ kit: ToolKit, _ connection: any ToolServerConnection, step: String) async throws -> [ServerTool] {
        do {
            return try await withTimeout(stepTimeout) { try await connection.tools() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw operationFailure(step: step, error: error)
        }
    }
}

private struct ServerToolInvocation: Sendable {
    let tool: ServerTool
    let connection: any ToolServerConnection
    let arguments: [String: Value]
    let request: PreparedRequest
}

/// Turns a Use a Tool step's rendered text into the types a server tool
/// asks for: numbers, yes/no, lists. Empty optional arguments are left out.
private enum ServerArguments {
    static func typed(_ rendered: [String: String], for tool: ServerTool) -> [String: Value] {
        var values: [String: Value] = [:]
        for (name, text) in rendered {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !tool.required.contains(name) { continue }
            let kind = tool.parameters.first { $0.name == name }?.kind ?? .text
            values[name] = value(trimmed, as: kind)
        }
        return values
    }

    private static func value(_ text: String, as kind: Field.Kind) -> Value {
        switch kind {
        case .number: return Double(text).map(Value.number) ?? .text(text)
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return .text(text)
            }
        case let .list(item):
            if let data = text.data(using: .utf8), let parsed = Value(json: data), case .list = parsed { return parsed }
            return .list(text.split(whereSeparator: \.isNewline).map { value(String($0).trimmingCharacters(in: .whitespaces), as: item) })
        case .text, .choice, .object:
            // A JSON object or list written into a text field is sent as one.
            if text.hasPrefix("{") || text.hasPrefix("["), let data = text.data(using: .utf8), let parsed = Value(json: data) {
                return parsed
            }
            return .text(text)
        }
    }
}
