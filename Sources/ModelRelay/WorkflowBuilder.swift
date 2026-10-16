import Foundation

/// Builds ordinary steps, including reusable arrays, into a workflow's tree.
/// Swift conditions and loops run while building the tree; use `ifEquals`
/// or `switchOn` steps for decisions made while executing the workflow.
@resultBuilder
public enum WorkflowBuilder {
    /// Adds one step.
    public static func buildExpression(_ step: Step) -> [Step] { [step] }
    /// Adds an existing group of steps without wrapping it in a block.
    public static func buildExpression(_ steps: [Step]) -> [Step] { steps }
    /// Joins the steps in declaration order; an empty block produces no steps.
    public static func buildBlock(_ components: [Step]...) -> [Step] { components.flatMap { $0 } }
    /// Supports a construction-time `if` without an `else`.
    public static func buildOptional(_ component: [Step]?) -> [Step] { component ?? [] }
    /// Supports the first construction-time conditional branch.
    public static func buildEither(first component: [Step]) -> [Step] { component }
    /// Supports the second construction-time conditional branch.
    public static func buildEither(second component: [Step]) -> [Step] { component }
    /// Supports a construction-time `for` loop.
    public static func buildArray(_ components: [[Step]]) -> [Step] { components.flatMap { $0 } }
    /// Supports availability checks while building the workflow.
    public static func buildLimitedAvailability(_ component: [Step]) -> [Step] { component }
}

extension Workflow {
    /// Builds the step tree immediately, without running models or tools.
    public init(
        name: String,
        id: UUID = UUID(),
        output: String? = nil,
        @WorkflowBuilder steps: () -> [Step]
    ) {
        self.init(id: id, name: name, steps: steps(), output: output)
    }

    public init(_ name: String, id: UUID = UUID(), output: String? = nil,
                @WorkflowBuilder steps: () -> [Step]) {
        self.init(name: name, id: id, output: output, steps: steps)
    }
}

extension SwitchCase {
    /// Builds the steps of one runtime switch case.
    public init(_ value: String, @WorkflowBuilder steps: () -> [Step]) {
        self.init(value, steps: steps())
    }
}
