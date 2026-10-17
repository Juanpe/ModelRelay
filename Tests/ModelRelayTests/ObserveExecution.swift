import ModelRelay

extension WorkflowExecutionStream {
    func observing(
        onStep: (StepRecord) -> Void = { _ in },
        onEvent: (WorkflowExecutionEvent) -> Void = { _ in }
    ) async throws -> Output {
        for try await update in self {
            switch update {
            case let .event(event): onEvent(event)
            case let .step(record): onStep(record)
            }
        }
        return try await result
    }
}
