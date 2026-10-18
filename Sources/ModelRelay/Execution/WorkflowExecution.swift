/// Execution metadata and step results; step records can contain user data.
public enum WorkflowExecutionUpdate: Sendable {
    case event(WorkflowExecutionEvent)
    case step(StepRecord)
}

/// Owns a running task, its progress and its independently awaitable result.
public final class WorkflowExecution<Output: Sendable>: Sendable {
    /// Single-consumer, unbounded progress. Keep the execution alive while consuming it.
    public let updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>
    private let task: Task<Output, any Error>

    init(operation: @escaping @Sendable (
        AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation
    ) async throws -> Output) {
        let (updates, continuation): (
            AsyncThrowingStream<WorkflowExecutionUpdate, any Error>,
            AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation
        ) = AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.makeStream()
        self.updates = updates

        let task: Task<Output, any Error> = Task {
            do {
                try Task.checkCancellation()
                let result: Output = try await operation(continuation)
                continuation.finish()
                return result
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        self.task = task

        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
    }

    deinit { task.cancel() }

    /// Awaiting the result does not consume updates. Cancelling the waiter cancels execution.
    public var result: Output {
        get async throws {
            try await withTaskCancellationHandler {
                let result: Output = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
            }
        }
    }

    /// Requests cooperative cancellation. Await `result` to wait for cleanup.
    public func cancel() { task.cancel() }
}
