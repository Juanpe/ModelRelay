import Foundation

extension Workflow {
    /// Preflight issues with the tools an agent or Use a Tool step selects.
    /// Server tools are discovered when the step runs, so they aren't checked here.
    func toolIssues(for step: Step, kits: [String: ToolKit], hostKits: [String: HostToolKit]) -> [WorkflowValidationIssue] {
        let selection: ToolSelection = .init(step: step, kits: kits, hostKits: hostKits)
        var issues: [WorkflowValidationIssue] = selection.unavailable.map { .init(step: step.name, kind: .unavailableTool, detail: $0) }

        let names: [String] = selection.requests.map(\.name) + selection.hosts.map(\.name)
        if Set(names).count != names.count { issues.append(.init(step: step.name, kind: .invalidSchema, detail: "tool names must be unique")) }
        let parameters: [[Field]] = selection.requests.map(\.parameters) + selection.hosts.map(\.parameters)
        issues += parameters.flatMap(\.schemaProblems).map { .init(step: step.name, kind: .invalidSchema, detail: $0) }

        return issues + referenceIssues(in: selection.requests, step: step.name)
    }

    /// Local kit templates can read workflow values too. No discovery/network here.
    private func referenceIssues(in tools: [AgentTool], step: String) -> [WorkflowValidationIssue] {
        let available: Set<String> = Set(availableSteps(before: step).map(\.name) + ["input"])
        let texts: [String] = tools.flatMap { [$0.request.url, $0.request.body ?? ""] + $0.request.headers.map(\.value) }

        return texts.flatMap { Template.references(in: $0) }
            .filter { !$0.hasPrefix("secret.") && !$0.hasPrefix("args.") }
            .filter { !available.contains($0.split(separator: ".").first.map(String.init) ?? "") }
            .map { .init(step: step, kind: .unavailableReference, detail: $0) }
    }
}

/// The tools a step selects from the executor's tool sets.
private struct ToolSelection {
    var requests: [AgentTool] = []
    var hosts: [HostTool] = []
    /// Why a selected kit or tool isn't available.
    var unavailable: [String] = []

    init(step: Step, kits: [String: ToolKit], hostKits: [String: HostToolKit]) {
        switch step.kind {
        case let .agent(_, own, ids):
            requests = own
            for id in ids ?? [] {
                add(kits[id], hostKits[id], id: id, tool: nil)
            }
        case let .useTool(id, name, _):
            add(kits[id], hostKits[id], id: id, tool: name)
        default:
            break
        }
    }

    private mutating func add(_ kit: ToolKit?, _ host: HostToolKit?, id: String, tool name: String?) {
        switch (kit, host) {
        case (.some, .some): unavailable.append("\(id) names both a tool kit and a host tool kit")
        case let (nil, host?): hosts += pick(host.tools, name: name) { $0.name }
        case let (kit?, nil): if kit.server == nil { requests += pick(kit.tools, name: name) { $0.name } }
        case (nil, nil): unavailable.append(id)
        }
    }

    /// Every tool for an agent; the named one for Use a Tool.
    private mutating func pick<Tool>(_ tools: [Tool], name: String?, _ toolName: (Tool) -> String) -> [Tool] {
        guard let name else { return tools }
        guard let tool = tools.first(where: { toolName($0) == name }) else {
            unavailable.append(name)
            return []
        }
        return [tool]
    }
}
