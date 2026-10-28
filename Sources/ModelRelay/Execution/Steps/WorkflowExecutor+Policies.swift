import Foundation

extension WorkflowExecutor {
    func effectivePolicy(for step: Step, scope: WorkflowExecutionScope) async -> WorkflowExecutionPolicy {
        var policy = scope.policy.combined(with: step.policy ?? .unrestricted)
        var references = Workflow.templates(in: step).flatMap { Template.references(in: $0.0) }
        if case let .handoff(values) = step.context { references += values }
        else if let input = step.input { references.append(input) }
        else { policy.data = policy.data.combined(with: scope.previousData) }
        switch step.kind {
        case let .ifEquals(value, _, _, _), let .switchOn(value, _, _): references.append(value)
        case .custom:
            // Custom bodies can read every result and the original input.
            policy.data = policy.data.combined(with: scope.inputData)
            for value in scope.valuePolicies.values {
                policy.data = policy.data.combined(with: value)
            }
        // Only request tools read workflow values through templates.
        case let .agent(_, _, kits):
            for case let .requests(kit)? in (kits ?? []).map({ toolSources[$0] }) {
                for tool in kit.tools {
                    references += ([tool.request.url, tool.request.body ?? ""] + tool.request.headers.map(\.value))
                        .flatMap { Template.references(in: $0) }
                }
            }
        case let .useTool(kitID, toolName, _):
            if case let .requests(kit)? = toolSources[kitID], let tool = kit.tools.first(where: { $0.name == toolName }) {
                references += ([tool.request.url, tool.request.body ?? ""] + tool.request.headers.map(\.value))
                    .flatMap { Template.references(in: $0) }
            }
        default: break
        }
        for reference in references {
            policy.data = policy.data.combined(with: scope.dataPolicy(for: reference))
        }
        let history = await scope.resources.historyPolicy(step.context, models: [step.model, step.fallback].compactMap { $0 })
        policy.data = policy.data.combined(with: history)
        return policy
    }
}
