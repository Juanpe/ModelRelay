import Foundation

extension Workflow {
    /// Reject shared mutable conversations across parallel branches before any
    /// model/tool/custom body runs. Separate conversations remain parallel.
    func validateContexts() throws {
        func keys(_ step: Step) throws -> Set<ExecutionResources.Key> {
            var own: Set<ExecutionResources.Key> = []
            if let context = step.context {
                switch step.kind {
                case .prompt, .extract, .classify, .agent, .decide, .readImage: break
                default: throw RelayError.invalidContext(step: step.name, reason: "context is only supported on model steps")
                }
                if case .conversation(let name) = context {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw RelayError.invalidContext(step: step.name, reason: "the conversation name is empty")
                    }
                    own = Set([step.model, step.fallback].compactMap { $0 }.map { ExecutionResources.Key(name: name, model: $0) })
                }
                if case .handoff = context {
                    guard step.input == nil else {
                        throw RelayError.invalidContext(step: step.name, reason: "handoff replaces input; do not also set input")
                    }
                    if case .readImage = step.kind {
                        throw RelayError.invalidContext(step: step.name, reason: "handoff carries values as text; use an explicit image input instead")
                    }
                }
            }
            let children: [Step]
            switch step.kind {
            case .parallel(let list):
                var seen: Set<ExecutionResources.Key> = []
                for child in list {
                    let childKeys = try keys(child)
                    guard seen.isDisjoint(with: childKeys) else {
                        throw RelayError.invalidContext(step: step.name, reason: "parallel branches must not share a conversation for the same model")
                    }
                    seen.formUnion(childKeys)
                }
                return own.union(seen)
            case .ifEquals(_, _, let yes, let no): children = yes + no
            case .switchOn(_, let cases, let other): children = cases.flatMap(\.steps) + other
            default: children = []
            }
            for child in children { own.formUnion(try keys(child)) }
            return own
        }
        for step in steps { _ = try keys(step) }
    }
}
