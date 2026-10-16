import ModelRelay

extension WorkflowExecutionStream {
    func observing(onStep: (StepRecord) -> Void = { _ in },
                   onEvent: (WorkflowExecutionEvent) -> Void = { _ in }) async throws -> Output {
        for try await update in self {
            switch update {
            case .event(let event): onEvent(event)
            case .step(let record): onStep(record)
            }
        }
        return try await result
    }
}
