/// Execution metadata and step results; step records can contain user data.
public enum WorkflowExecutionUpdate: Sendable {
    case event(WorkflowExecutionEvent)
    case step(StepRecord)
}

/// A single-consumer progress stream with a separately awaitable result.
public final class WorkflowExecutionStream<Output: Sendable>: AsyncSequence, Sendable {
    public typealias Element = WorkflowExecutionUpdate

    private let updates: AsyncThrowingStream<Element, any Error>
    private let task: Task<Output, any Error>

    init(operation: @escaping @Sendable (
        @escaping @Sendable (StepRecord) -> Void,
        @escaping @Sendable (WorkflowExecutionEvent) -> Void
    ) async throws -> Output) {
        let (updates, continuation) = AsyncThrowingStream<Element, any Error>.makeStream()
        self.updates = updates
        let task = Task {
            do {
                try Task.checkCancellation()
                let result = try await operation(
                    { continuation.yield(.step($0)) },
                    { continuation.yield(.event($0)) }
                )
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
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
            }
        }
    }

    /// Requests cooperative cancellation. Await `result` to wait for cleanup.
    public func cancel() { task.cancel() }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(execution: self, iterator: updates.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        // Keep a temporary execution alive until its iterator is released.
        private let execution: WorkflowExecutionStream
        private var iterator: AsyncThrowingStream<Element, any Error>.AsyncIterator

        fileprivate init(execution: WorkflowExecutionStream,
                         iterator: AsyncThrowingStream<Element, any Error>.AsyncIterator) {
            self.execution = execution
            self.iterator = iterator
        }

        public mutating func next() async throws -> Element? {
            if Task.isCancelled { execution.cancel(); throw CancellationError() }
            let update = try await iterator.next()
            if Task.isCancelled { execution.cancel(); throw CancellationError() }
            return update
        }
    }
}
