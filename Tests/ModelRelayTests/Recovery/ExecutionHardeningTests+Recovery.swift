import Foundation
import Synchronization
import Testing
@testable import ModelRelay

extension ExecutionHardeningTests {
    @Test func checkpointsPreserveUsageLimitsAndEventIdentityAcrossResume() async throws {
        let model = ScriptedModel("model", replies: ["draft", "must not run"])
        let catalog = ModelCatalog().registering("model") { model }
        let workflow = Workflow("Durable limits") {
            Step.prompt("draft", "Draft", model: "model")
            Step.prompt("review", "Review", model: "model").requiringApproval("Review")
        }
        let events = Mutex<[WorkflowExecutionEvent]>([])
        let store = HardeningStore()
        let outcome = try await WorkflowExecutor(catalog: catalog, limits: .init(maxModelCalls: 1))
            .startExecution(workflow, input: .null, revision: "1", store: store)
            .observing(onEvent: { event in events.withLock { $0.append(event) } })
        guard case let .awaitingApproval(checkpoint) = outcome else { Issue.record("expected pause"); return }
        #expect(checkpoint.usage.modelCalls == 1)
        #expect(checkpoint.limits.maxModelCalls == 1)
        #expect(events.withLock { $0.last?.kind } == .approvalRequired)
        let oldInvocation = events.withLock { $0.first?.invocationID }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog).resumeExecution(
                workflow,
                from: checkpoint,
                revision: "1",
                approval: .approve,
                store: store,
                limits: .init(maxModelCalls: 99)
            )
            .observing(onEvent: { event in events.withLock { $0.append(event) } })
        }
        #expect(model.callCount == 1)
        let saved = try await store.latest()
        #expect(saved.status == .running)
        #expect(saved.limits.maxModelCalls == 1)
        #expect(events.withLock { $0.allSatisfy { $0.executionID == checkpoint.executionID } })
        #expect(events.withLock { $0.last?.invocationID } != oldInvocation)
    }

    @Test func approvalAndCheckpointEventsAreEmittedOnlyAfterDurableSaves() async throws {
        let workflow = Workflow("Gated") { Step.template("gate", "value").requiringApproval("Review") }
        let events = Mutex<[WorkflowExecutionEvent]>([])
        let store = HardeningStore()
        let pending = try await WorkflowExecutor().startExecution(workflow, input: .null, revision: "1", store: store)
            .observing(onEvent: { event in events.withLock { $0.append(event) } })
        guard case let .awaitingApproval(checkpoint) = pending else { Issue.record("expected pause"); return }
        #expect(events.withLock { $0.map(\.kind) } == [.executionStarted, .checkpointSaved, .checkpointSaved, .approvalRequired])
        _ = try await WorkflowExecutor().resumeExecution(workflow, from: checkpoint, revision: "1", approval: .reject, store: store)
            .observing(onEvent: { event in events.withLock { $0.append(event) } })
        #expect(events.withLock { $0.last?.kind } == .approvalRejected)
        #expect(events.withLock { !$0.contains { $0.kind == .stepStarted } })
    }

    @Test func consumedDurationSurvivesPauseAndCannotBeResetOnResume() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Time across pause") {
            Step.custom("first") { _ in try await Task.sleep(for: .milliseconds(20)); return .null }
            Step.custom("second") { _ in calls.withLock { $0 += 1 }; return .null }.requiringApproval("Review")
        }
        let store = HardeningStore()
        let result = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
        guard case let .awaitingApproval(checkpoint) = result else { Issue.record("expected pause"); return }
        let shorter = checkpoint.state.duration - .milliseconds(1)
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().resume(
                workflow,
                from: checkpoint,
                revision: "1",
                approval: .approve,
                store: store,
                limits: .init(maxDuration: shorter)
            )
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func narrowingLimitsAtAPendingApprovalPersistsANewGeneration() async throws {
        let workflow = Workflow("Narrow pending") { Step.template("gate", "ok").requiringApproval("Review") }
        let store = HardeningStore()
        let first = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
        guard case let .awaitingApproval(checkpoint) = first else { Issue.record("expected pause"); return }
        _ = try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store, limits: .init(maxToolCalls: 0))
        let saved = try await store.latest()
        #expect(saved.generation == checkpoint.generation + 1)
        #expect(saved.limits.maxToolCalls == 0)
        await #expect(throws: RecoveryError.checkpointConflict) {
            try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", approval: .approve, store: store)
        }
    }

    @Test func durationLimitedReconciliationRequiresExplicitAccountingOfLostTime() async throws {
        let workflow = Workflow("Reconcile time") {
            Step.custom("interrupted") { _ in throw HostProblem.rejected }
            Step.template("next", "must not run")
        }
        let store = HardeningStore()
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store, limits: .init(maxDuration: .seconds(1)))
        }
        let checkpoint = try await store.latest()
        await #expect(throws: RecoveryError.self) {
            try await WorkflowExecutor().confirmCompletion(checkpoint, in: workflow, revision: "1", value: .text("verified"), store: store)
        }
        let ready = try await WorkflowExecutor().confirmCompletion(
            checkpoint,
            in: workflow,
            revision: "1",
            value: .text("verified"),
            elapsed: .seconds(2),
            store: store
        )
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().resume(workflow, from: ready, revision: "1", store: store, limits: .init(maxDuration: .seconds(99)))
        }
    }
}
