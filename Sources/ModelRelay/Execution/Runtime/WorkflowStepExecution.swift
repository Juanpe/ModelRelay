import Foundation

/// Input, permissions and timing captured once for a step's handlers.
struct WorkflowStepExecution: Sendable {
    let step: Step
    let source: Value
    let context: RequestContext
    let trace: StepTrace
    let clock: ContinuousClock
    let startedAt: ContinuousClock.Instant

    func record(
        _ value: Value,
        model: ModelID? = nil,
        usedFallback: Bool = false,
        toolCalls: [String] = []
    ) -> StepRecord {
        StepRecord(
            step: step.name,
            value: value,
            model: model,
            usedFallback: usedFallback,
            duration: clock.now - startedAt,
            skipped: false,
            toolCalls: toolCalls,
            input: trace.input
        )
    }
}
