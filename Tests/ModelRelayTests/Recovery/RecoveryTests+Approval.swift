import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

extension RecoveryTests {
    @Test func ordinaryRunRejectsGatesBeforeAnyWork() async {
        let calls = Mutex(0)
        let workflow = Workflow("Must use recovery") {
            Step.custom("before") { _ in calls.withLock { $0 += 1 }; return .null }
            Step.template("gate", "ok").requiringApproval("Check")
        }
        await #expect(throws: RecoveryError.approvalRequired(step: "gate")) {
            try await WorkflowExecutor().run(workflow, input: .null)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func nestedGatesAreRejectedBeforeSavingOrRunning() async {
        let store = MemoryCheckpoints()
        let workflow = Workflow("Nested") {
            Step.parallel("block") { Step.template("inner", "x").requiringApproval("No") }
        }
        await #expect(throws: (any Error).self) {
            try await WorkflowExecutor().start(workflow, input: .null, revision: "v1", store: store)
        }
        #expect(await store.saves.isEmpty)
    }

    @Test func eachGateNeedsItsOwnApprovalAndStreamedRecordsDoNotReplay() async throws {
        let store = MemoryCheckpoints()
        let observed = Mutex<[String]>([])
        let workflow = Workflow("Two gates") {
            Step.template("first", "one").requiringApproval("First")
            Step.template("second", "two").requiringApproval("Second")
        }
        let executor = WorkflowExecutor()
        let first = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        let second = try paused(await executor.resumeExecution(workflow, from: first, revision: "1", approval: .approve, store: store)
            .observing(onStep: { record in observed.withLock { $0.append(record.step) } }))
        #expect(second.step == "second")
        _ = try completed(await executor.resumeExecution(workflow, from: second, revision: "1", approval: .approve, store: store)
            .observing(onStep: { record in observed.withLock { $0.append(record.step) } }))
        #expect(observed.withLock { $0 } == ["first", "second"])
    }

    @Test func rejectionIsTerminalAndStaleApprovalCannotRun() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Reject") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .null }.requiringApproval("Confirm")
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        let gate = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        guard case let .rejected(rejected) = try await executor.resume(workflow, from: gate, revision: "1", approval: .reject, store: store) else {
            Issue.record("expected rejection"); return
        }
        guard case .rejected = try await executor.resume(workflow, from: rejected, revision: "1", store: store) else {
            Issue.record("rejection was not terminal"); return
        }
        await #expect(throws: RecoveryError.checkpointConflict) {
            try await executor.resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func approvingStepDoesNotGrantWritePermission() async throws {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("Permission") {
            Step.request("write", HTTPRequest(.post, url: "https://example.test/write")).requiringApproval("Check")
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor(requests: server)
        let gate = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        await #expect(throws: RelayError.writeNotAllowed(step: "write")) {
            try await executor.resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func approvalsRoundTripAndOldStepJSONRemainsCompatible() throws {
        let step = Step.template("value", "text").requiringApproval("Check")
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
        let old = Data(#"{"name":"value","kind":{"template":{"_0":"text"}}}"#.utf8)
        #expect(try JSONDecoder().decode(Step.self, from: old).approval == nil)
    }
}
