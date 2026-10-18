import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

extension RecoveryTests {
    @Test func concurrentResumesClaimAStepOnlyOnce() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Race") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .text("done") }.requiringApproval("Confirm")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        _ = try await WorkflowExecutor().resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success {
                count += 1
            }
            return count
        }
        #expect(successes == 1)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [0, 1]) func failedInitialOrClaimSaveNeverRunsCode(generation: Int) async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Durable first") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .text("done") }
        }
        let store = MemoryCheckpoints(failBefore: generation)
        await #expect(throws: StoreFailure.self) {
            try await WorkflowExecutor().startExecution(workflow, input: .null, revision: "1", store: store).observing()
        }
        #expect(calls.withLock { $0 } == 0)
        if generation == 1 {
            let ready = try await store.latest()
            #expect(ready.status == .ready)
            _ = try completed(await WorkflowExecutor().resume(workflow, from: ready, revision: "1", store: store))
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func claimIsVisibleBeforeCallingHostCode() async throws {
        let store = MemoryCheckpoints()
        let workflow = Workflow("Order") {
            Step.custom("effect") { _ in
                let saved = try await store.latest()
                #expect(saved.status == .running)
                #expect(saved.step == "effect")
                return .text("done")
            }
        }
        _ = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
    }

    @Test func failedPostStepSaveRequiresReconciliationAndNeverResendsWrite() async throws {
        let server = FakeServer(json: #"{"id":7}"#)
        let store = MemoryCheckpoints(failBefore: 2)
        let workflow = Workflow("Create") {
            Step.request("create", HTTPRequest(.post, url: "https://example.test/tasks"))
            Step.template("format", "Created {{create.id}}")
        }
        let executor = WorkflowExecutor(requests: server, writePolicy: .allow)
        let execution = executor.startExecution(workflow, input: .null, revision: "1", store: store)
        let records = Mutex<[StepRecord]>([])
        let savedGenerations = Mutex<[Int]>([])
        await #expect(throws: StoreFailure.self) {
            try await execution.observing(
                onStep: { record in records.withLock { $0.append(record) } },
                onEvent: { event in
                    if let generation = event.checkpointGeneration { savedGenerations.withLock { $0.append(generation) } }
                }
            )
        }
        await #expect(throws: StoreFailure.self) { try await execution.result }
        #expect(records.withLock { $0.map(\.step) } == ["create"])
        #expect(savedGenerations.withLock { $0 } == [0, 1])
        let interrupted = try await store.latest()
        #expect(interrupted.status == .running)
        await #expect(throws: RecoveryError.interrupted(step: "create")) {
            try await executor.resume(workflow, from: interrupted, revision: "1", store: store)
        }
        // The caller verified the remote object independently. No request occurs.
        let ready = try await executor.confirmCompletion(
            interrupted,
            in: workflow,
            revision: "1",
            value: .dictionary(["id": .number(7)]),
            store: store
        )
        let report = try completed(await executor.resume(workflow, from: ready, revision: "1", store: store))
        #expect(server.requests.count == 1)
        #expect(report.output == .text("Created 7"))
        #expect(report.records.first?.recovered == true)
        #expect(report.usage.toolCalls == 1)
        await #expect(throws: RecoveryError.checkpointConflict) {
            try await executor.confirmCompletion(interrupted, in: workflow, revision: "1", value: .null, store: store)
        }
    }

    @Test func lostSaveAcknowledgementLoadsConfirmedResultWithoutReplay() async throws {
        let calls = Mutex(0)
        let store = MemoryCheckpoints(failAfter: 2)
        let workflow = Workflow("Lost ack") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .text("done") }
        }
        let generations = Mutex<[Int]>([])
        await #expect(throws: StoreFailure.self) {
            try await WorkflowExecutor().startExecution(workflow, input: .null, revision: "1", store: store)
                .observing(onEvent: { event in
                    if let generation = event.checkpointGeneration { generations.withLock { $0.append(generation) } }
                })
        }
        #expect(generations.withLock { $0 } == [0, 1])
        let checkpoint = try await store.latest()
        #expect(checkpoint.status == .completed)
        let report = try completed(await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store))
        #expect(report.output == .text("done"))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func cancellingARecoverableStreamKeepsItsRunningClaim() async throws {
        let calls = Mutex(0)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Interrupted stream") {
            Step.custom("effect") { _ in
                calls.withLock { $0 += 1 }
                continuation.yield(); continuation.finish()
                try await Task.sleep(for: .seconds(10))
                return .text("done")
            }
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        let execution = executor.startExecution(workflow, input: .null, revision: "1", store: store)
        for await _ in started {
            break
        }
        execution.cancel()
        await #expect(throws: CancellationError.self) { try await execution.result }
        let checkpoint = try await store.latest()
        #expect(checkpoint.status == .running)
        await #expect(throws: RecoveryError.interrupted(step: "effect")) {
            try await executor.resumeExecution(workflow, from: checkpoint, revision: "1", store: store).observing()
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func failedModelAttemptRemainsAmbiguousNotAnAutomaticRetry() async throws {
        let model = ScriptedModel("model", replies: [nil, "must not run"])
        let workflow = Workflow("Fail") { Step.prompt("ask", "Q", model: "model") }
        let executor = WorkflowExecutor(catalog: .scripted(["model": model]))
        let store = MemoryCheckpoints()
        await #expect(throws: (any Error).self) { try await executor.start(workflow, input: .null, revision: "1", store: store) }
        let checkpoint = try await store.latest()
        await #expect(throws: RecoveryError.interrupted(step: "ask")) {
            try await executor.resume(workflow, from: checkpoint, revision: "1", store: store)
        }
        await #expect(throws: (any Error).self) {
            try await executor.confirmCompletion(checkpoint, in: workflow, revision: "1", value: .text("fake"), store: store)
        }
        #expect(model.callCount == 1)
    }

    @Test func cancellationKeepsRunningMarkerAndNeverRepeatsBody() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Cancel") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; throw CancellationError() }
        }
        let executor = WorkflowExecutor()
        let store = MemoryCheckpoints()
        await #expect(throws: CancellationError.self) { try await executor.start(workflow, input: .null, revision: "1", store: store) }
        let checkpoint = try await store.latest()
        #expect(checkpoint.status == .running)
        await #expect(throws: RecoveryError.interrupted(step: "effect")) {
            try await executor.resume(workflow, from: checkpoint, revision: "1", store: store)
        }
        #expect(calls.withLock { $0 } == 1)
    }
}
