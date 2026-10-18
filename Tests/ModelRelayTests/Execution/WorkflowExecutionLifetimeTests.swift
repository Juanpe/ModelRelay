import Foundation
import Synchronization
import Testing
@testable import ModelRelay

private actor StreamTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(ready: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            ready.yield(); ready.finish()
        }
    }

    func open() { continuation?.resume(); continuation = nil }
}

@Suite(.timeLimit(.minutes(1))) struct WorkflowExecutionLifetimeTests {
    @Test func droppingAnUnconsumedExecutionCancelsItsWork() async throws {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Lifetime") {
            Step.custom("slow") { _ in
                defer { stop.yield(); stop.finish() }
                start.yield(); start.finish()
                try await Task.sleep(for: .seconds(10))
                return .null
            }
        }
        var execution: WorkflowExecution<WorkflowExecutionReport>? = WorkflowExecutor().execute(workflow, input: .null)
        weak let released = execution
        for await _ in started {
            break
        }
        execution = nil
        #expect(released == nil)
        #expect(await stopped.first(where: { _ in true }) != nil)
    }

    @Test func anAlreadyCancelledResultWaiterStillWaitsForCleanup() async throws {
        let waiterGate = StreamTestGate()
        let cleanupGate = StreamTestGate()
        let (waiterReady, ready) = AsyncStream<Void>.makeStream()
        let (cleanupStarted, cleanup) = AsyncStream<Void>.makeStream()
        let (bodyStarted, body) = AsyncStream<Void>.makeStream()
        let returned = Mutex(false)
        let workflow = Workflow(name: "Cleanup") {
            Step.custom("slow") { _ in
                body.yield(); body.finish()
                do {
                    try await Task.sleep(for: .seconds(10))
                    return .null
                } catch {
                    await cleanupGate.wait(ready: cleanup)
                    throw error
                }
            }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        defer { execution.cancel() }
        for await _ in bodyStarted {
            break
        }
        let waiter = Task {
            await waiterGate.wait(ready: ready)
            defer { returned.withLock { $0 = true } }
            return try await execution.result
        }
        for await _ in waiterReady {
            break
        }
        waiter.cancel()
        await waiterGate.open()
        for await _ in cleanupStarted {
            break
        }
        #expect(!returned.withLock { $0 })
        await cleanupGate.open()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(returned.withLock { $0 })
    }

    @Test func retainedNativeUpdatesDoNotKeepTheExecutionAlive() async throws {
        let (started, start): (AsyncStream<Void>, AsyncStream<Void>.Continuation) = AsyncStream<Void>.makeStream()
        let (stopped, stop): (AsyncStream<Void>, AsyncStream<Void>.Continuation) = AsyncStream<Void>.makeStream()
        let workflow: Workflow = .init(name: "Handle ownership") {
            Step.custom("slow") { _ in
                defer { stop.yield(); stop.finish() }
                start.yield(); start.finish()
                try await Task.sleep(for: .seconds(10))
                return .null
            }
        }
        var execution: WorkflowExecution<WorkflowExecutionReport>? = WorkflowExecutor().execute(workflow, input: .null)
        weak let released: WorkflowExecution<WorkflowExecutionReport>? = execution
        let updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error> = try #require(execution).updates

        for await _ in started {
            break
        }

        execution = nil
        #expect(released == nil)
        #expect(await stopped.contains(where: { _ in true }))
        await #expect(throws: CancellationError.self) {
            for try await _ in updates {}
        }
    }

    @Test func breakingIterationDoesNotCancelARetainedExecution() async throws {
        let (release, permit): (AsyncStream<Void>, AsyncStream<Void>.Continuation) = AsyncStream<Void>.makeStream()
        let workflow: Workflow = .init(name: "Leave updates") {
            Step.template("first", "ready")
            Step.custom("finish") { _ in
                for await _ in release {
                    break
                }
                try Task.checkCancellation()
                return .text("done")
            }
        }
        let execution: WorkflowExecution<WorkflowExecutionReport> = WorkflowExecutor().execute(workflow, input: .null)
        defer { execution.cancel(); permit.finish() }

        for try await update in execution.updates {
            if case .step = update { break }
        }

        permit.yield(); permit.finish()
        #expect(try await execution.result.output == .text("done"))
    }

    @Test func explicitCancellationWaitsForBodyCleanupAndDoesNotRunTheNextStep() async throws {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Cancel") {
            Step.custom("slow") { _ in
                defer { stop.yield(); stop.finish() }
                start.yield(); start.finish()
                try await Task.sleep(for: .seconds(10))
                return .null
            }
            Step.custom("never") { _ in Issue.record("ran after cancellation"); return .null }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        for await _ in started {
            break
        }
        execution.cancel()
        await #expect(throws: CancellationError.self) { try await execution.result }
        #expect(await stopped.first(where: { _ in true }) != nil)
        var kinds: [WorkflowExecutionEvent.Kind] = []
        await #expect(throws: CancellationError.self) {
            for try await update in execution.updates {
                if case let .event(event) = update { kinds.append(event.kind) }
            }
        }
        #expect(kinds.last == .executionCancelled)
        #expect(!kinds.contains(.executionCompleted))
    }

    @Test func cancellingAnIteratorCancelsTheProducer() async throws {
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Consumer cancellation") {
            Step.custom("slow") { _ in
                defer { stop.yield(); stop.finish() }
                try await Task.sleep(for: .seconds(10))
                return .null
            }
        }
        let (started, start) = AsyncStream<Void>.makeStream()
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        let consumer = Task {
            for try await update in execution.updates {
                if case let .event(event) = update, event.kind == .stepStarted {
                    start.yield(); start.finish()
                }
            }
        }
        for await _ in started {
            break
        }
        consumer.cancel()
        try await consumer.value
        await #expect(throws: CancellationError.self) { try await execution.result }
        // A cancellation can win before the custom body starts.
        stop.finish()
        _ = await stopped.first(where: { _ in true })
    }
}
