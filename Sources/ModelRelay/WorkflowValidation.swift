import Foundation

public struct WorkflowValidationIssue: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case invalidName, duplicateName, unavailableReference, missingModel, unknownModel
        case incompatibleModel, invalidSchema, unavailableTool, invalidContext, invalidVersion
    }
    public let step: String
    public let kind: Kind
    public let detail: String
}

/// All statically detectable issues, found without loading a model or connecting
/// to a server. Dynamic response fields, credentials and MCP schemas remain runtime checks.
public struct WorkflowValidationError: Error, Equatable, Sendable {
    public let issues: [WorkflowValidationIssue]
}

extension Workflow {
    func validationIssues(catalog: ModelCatalog, kits: [String: ToolKit]) -> [WorkflowValidationIssue] {
        var issues: [WorkflowValidationIssue] = []
        func issue(_ step: String, _ kind: WorkflowValidationIssue.Kind, _ detail: String) {
            issues.append(.init(step: step, kind: kind, detail: detail))
        }
        if schemaVersion != Self.currentSchemaVersion { issue("Workflow", .invalidVersion, "unsupported workflow schema") }
        for ref in referenceIssues { issue(ref.step, .unavailableReference, ref.reference) }
        var names: Set<String> = []
        let knownModels = Set(catalog.ids)
        func fields(_ fields: [Field], step: String) {
            if Set(fields.map(\.name)).count != fields.count || fields.contains(where: { $0.name.isEmpty }) {
                issue(step, .invalidSchema, "fields need unique nonempty names")
            }
            func kind(_ value: Field.Kind) {
                switch value {
                case .choice(let options):
                    if options.isEmpty || options.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) || Set(options).count != options.count {
                        issue(step, .invalidSchema, "choices must be nonempty and unique")
                    }
                case .list(let item): kind(item)
                default: break
                }
            }
            for field in fields { kind(field.kind) }
        }
        func visit(_ steps: [Step]) {
            for step in steps {
                if step.name.isEmpty || step.name.contains(".") || ["input", "secret", "args"].contains(step.name) {
                    issue(step.name, .invalidName, "step names must be nonempty, unreserved and contain no dots")
                }
                if !names.insert(step.name).inserted { issue(step.name, .duplicateName, "step names must be unique across the workflow") }
                let needsModel: Bool
                switch step.kind {
                case .prompt, .extract, .classify, .agent, .decide, .readImage: needsModel = true
                default: needsModel = false
                }
                if needsModel {
                    if step.model == nil { issue(step.name, .missingModel, "this step needs a model") }
                    for id in [step.model, step.fallback].compactMap({ $0 }) where !knownModels.contains(id) {
                        issue(step.name, .unknownModel, id.rawValue)
                    }
                    func compatible(_ id: ModelID) -> Bool {
                        if id == .appleTextRecognition { if case .readImage = step.kind { return true }; return false }
                        switch step.kind {
                        case .readImage: return !catalog.isDecision(id) && catalog.supportsImages(id)
                        case .classify, .decide: return true
                        default: return !catalog.isDecision(id)
                        }
                    }
                    let candidates = [step.model, step.fallback].compactMap { $0 }.filter { knownModels.contains($0) }
                    // An explicitly configured compatible fallback remains valid.
                    if !candidates.isEmpty, !candidates.contains(where: compatible) {
                        issue(step.name, .incompatibleModel, "no configured model supports this step")
                    }
                }
                var tools: [AgentTool] = []
                switch step.kind {
                case .extract(_, let values): fields(values, step: step.name)
                case .classify(_, let labels):
                    if labels.isEmpty || labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) || Set(labels.map { $0.lowercased() }).count != labels.count {
                        issue(step.name, .invalidSchema, "labels must be nonempty and distinct ignoring case")
                    }
                case .decide(let questions):
                    if let problem = Question.problem(in: questions) { issue(step.name, .invalidSchema, problem) }
                case .agent(_, let own, let ids):
                    tools = own
                    for id in ids ?? [] {
                        if let kit = kits[id] { if kit.server == nil { tools += kit.tools } }
                        else { issue(step.name, .unavailableTool, id) }
                    }
                case .useTool(let id, let name, _):
                    if let kit = kits[id] {
                        if kit.server == nil {
                            if let tool = kit.tools.first(where: { $0.name == name }) { tools = [tool] }
                            else { issue(step.name, .unavailableTool, name) }
                        }
                    } else { issue(step.name, .unavailableTool, id) }
                case .parallel(let children): visit(children)
                case .ifEquals(_, _, let yes, let no): visit(yes); visit(no)
                case .switchOn(_, let cases, let otherwise):
                    let keys = cases.map { $0.value.trimmingCharacters(in: .whitespaces).lowercased() }
                    if Set(keys).count != keys.count { issue(step.name, .invalidSchema, "switch cases must be distinct ignoring case") }
                    for item in cases { visit(item.steps) }; visit(otherwise)
                default: break
                }
                if Set(tools.map(\.name)).count != tools.count { issue(step.name, .invalidSchema, "tool names must be unique") }
                for tool in tools { fields(tool.parameters, step: step.name) }
                // Local kit templates can read workflow values too. No discovery/network here.
                for tool in tools {
                    let available = Set(availableSteps(before: step.name).map(\.name) + ["input"])
                    let texts = [tool.request.url, tool.request.body ?? ""] + tool.request.headers.map(\.value)
                    for ref in texts.flatMap({ Template.references(in: $0) }) where !ref.hasPrefix("secret.") && !ref.hasPrefix("args.") {
                        let base = ref.split(separator: ".").first.map(String.init) ?? ""
                        if !available.contains(base) { issue(step.name, .unavailableReference, ref) }
                    }
                }
            }
        }
        visit(steps)
        do { try validateContexts() } catch { issue("Workflow", .invalidContext, failureReason(error)) }
        return Array(Set(issues)).sorted {
            ($0.step, $0.kind.rawValue, $0.detail) < ($1.step, $1.kind.rawValue, $1.detail)
        }
    }
}
