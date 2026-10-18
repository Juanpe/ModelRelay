import ModelRelay

extension WorkflowExecution {
    func observing(
        onStep: (StepRecord) -> Void = { _ in },
        onEvent: (WorkflowExecutionEvent) -> Void = { _ in }
    ) async throws -> Output {
        for try await update in updates {
            switch update {
            case let .event(event): onEvent(event)
            case let .step(record): onStep(record)
            }
        }
        return try await result
    }
}
