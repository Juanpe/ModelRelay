import CryptoKit
import Foundation

extension Workflow {
    func validateApprovals(recoverable: Bool) throws {
        func visit(_ steps: [Step], nested: Bool) throws {
            for step in steps {
                if step.approval != nil {
                    guard recoverable else { throw RecoveryError.approvalRequired(step: step.name) }
                    guard !nested else {
                        throw RecoveryError.unsupported("approval gates must be on top-level steps; gate the containing block")
                    }
                }
                for branch in step.recoveryChildren {
                    try visit(branch, nested: true)
                }
            }
        }
        try visit(steps, nested: false)
    }

    /// Compiled bodies are deliberately not encoded. Their location/shape is
    /// bound here; their executable implementation is bound by the HOST revision.
    /// This digest is a change detector, not authentication for untrusted state.
    func recoveryDefinition(kits: [ToolKit]) throws -> String {
        struct Definition: Encodable {
            var workflow: Workflow
            var customPaths: [String]
            var kits: [ToolKit]
        }
        var paths: [String] = []
        var names: Set<String> = []
        func prepare(_ steps: [Step], path: String) throws -> [Step] {
            try steps.enumerated().map { index, step in
                guard !step.name.isEmpty, step.name != "input", names.insert(step.name).inserted else {
                    throw RecoveryError.unsupported("recoverable workflows require unique, nonempty step names other than input")
                }
                var copy = step
                let location = "\(path)/\(index)"
                switch step.kind {
                case .custom:
                    paths.append(location)
                    copy.kind = .template("")
                case let .parallel(children):
                    copy.kind = .parallel(try prepare(children, path: location))
                case let .ifEquals(ref, value, yes, no):
                    copy.kind = .ifEquals(
                        reference: ref,
                        value: value,
                        then: try prepare(yes, path: location + "/then"),
                        otherwise: try prepare(no, path: location + "/otherwise")
                    )
                case let .switchOn(ref, cases, otherwise):
                    let cases = try cases.enumerated().map { i, item in
                        SwitchCase(item.value, steps: try prepare(item.steps, path: "\(location)/case/\(i)"))
                    }
                    copy.kind = .switchOn(
                        reference: ref,
                        cases: cases,
                        otherwise: try prepare(otherwise, path: location + "/otherwise")
                    )
                default: break
                }
                return copy
            }
        }
        var copy = self
        copy.steps = try prepare(steps, path: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Definition(workflow: copy, customPaths: paths, kits: kits.sorted { $0.id < $1.id }))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Step {
    var recoveryChildren: [[Step]] {
        switch kind {
        case let .parallel(children): [children]
        case let .ifEquals(_, _, yes, no): [yes, no]
        case let .switchOn(_, cases, otherwise): cases.map(\.steps) + [otherwise]
        default: []
        }
    }
}
