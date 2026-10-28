import AnyLanguageModel
import Foundation

extension WorkflowExecutor {
    func runAgentStep(_ execution: WorkflowStepExecution, scope: inout WorkflowExecutionScope) async throws -> Value {
        let step: Step = execution.step
        let source: Value = execution.source
        let trace: StepTrace = execution.trace

        guard let primary = step.model else { throw RelayError.missingModel(step: step.name) }
        let definitions: AgentToolDefinitions = try await agentToolDefinitions(for: step, scope: scope)

        let prompt = WorkflowModelRuntime.prompt(for: step.kind, source: source, resolve: scope.resolve)
        trace.input = prompt
        let log = ToolCallLog(limit: AgentTool.maxCallsPerStep)
        defer { log.finish() }
        let tools: [any Tool] = definitions.bind(to: execution, scope: scope, log: log)

        var model = primary
        var usedFallback = false
        let value: Value
        do {
            value = try await modelRuntime.generate(.prompt(instruction: ""), prompt: prompt, model: primary, tools: tools, step: step, scope: scope)
        } catch let error as RelayError where error == .unknownModel(primary) {
            throw error
        } catch {
            try rethrowExecutionControlError(error)
            // A tool may already have changed something: only retry on the
            // fallback model when no tool was called.
            guard let fallback = step.fallback, log.calls.isEmpty else {
                throw operationFailure(step: step.name, error: error, uncertain: log.mayHaveWritten)
            }
            scope.control.emit(.fallbackSelected, step: step.name, model: fallback)
            do {
                value = try await modelRuntime.generate(.prompt(instruction: ""), prompt: prompt, model: fallback, tools: tools, step: step, scope: scope)
                model = fallback
                usedFallback = true
            } catch {
                try rethrowExecutionControlError(error)
                throw operationFailure(step: step.name, error: error, uncertain: log.mayHaveWritten)
            }
        }
        scope.record(execution.record(value, model: model, usedFallback: usedFallback, toolCalls: log.calls))
        return value
    }

    private func agentToolDefinitions(for step: Step, scope: WorkflowExecutionScope) async throws -> AgentToolDefinitions {
        guard case let .agent(_, ownTools, kitIDs) = step.kind else { throw InvalidOutput(reason: "Expected an agent step") }
        var specs: [AgentTool] = ownTools
        var servers: [ConnectedToolKit] = []

        for id in scope.policy.tools == .denied ? [] : kitIDs ?? [] {
            if let host = hostToolKits[id] {
                servers.append(ConnectedToolKit(kit: host.toolKit, connection: host.connection, tools: host.tools.map(\.serverTool), reachesNetwork: false))
                continue
            }
            guard let kit = toolKits[id] else {
                throw RelayError.stepFailed(step: step.name, reason: "the tool set “\(id)” isn't available")
            }
            if kit.server != nil {
                let connection: any ToolServerConnection = try await connect(kit, step: step.name, policy: scope.policy)
                servers.append(ConnectedToolKit(kit: kit, connection: connection, tools: try await serverTools(kit, connection, step: step.name), reachesNetwork: true))
            } else {
                specs += kit.tools
            }
        }

        return AgentToolDefinitions(specs: specs, servers: servers)
    }
}

private struct ConnectedToolKit: Sendable {
    let kit: ToolKit
    let connection: any ToolServerConnection
    let tools: [ServerTool]
    let reachesNetwork: Bool
}

private struct AgentToolDefinitions: Sendable {
    let specs: [AgentTool]
    let servers: [ConnectedToolKit]

    func bind(to execution: WorkflowStepExecution, scope: WorkflowExecutionScope, log: ToolCallLog) -> [any Tool] {
        let snapshot: WorkflowExecutionScope = scope
        let specs: [AgentTool] = specs.filter {
            scope.policy.data != .localOnly && scope.policy.allowsTool(changesSomething: $0.request.method.isWrite)
        }
        var tools: [any Tool] = specs.map {
            RequestTool(spec: $0, step: execution.step.name, context: execution.context, log: log, resolve: { snapshot.resolve($0) })
        }

        for server in servers {
            tools += server.tools.filter { scope.policy.allowsTool(changesSomething: $0.changesSomething) }.map { ServerToolCall(
                tool: $0,
                kit: server.kit,
                connection: server.connection,
                reachesNetwork: server.reachesNetwork,
                step: execution.step.name,
                context: execution.context,
                log: log
            ) }
        }

        return tools
    }
}
