import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

private enum StoreFailure: Error { case unavailable }

/// Test-only, JSON round-tripping CAS store. Production storage is host-owned.
private actor MemoryCheckpoints: WorkflowExecutionCheckpointStore {
    private var data: [UUID: Data] = [:]
    private var history: [WorkflowExecutionCheckpoint] = []
    var failBefore: Int?
    var failAfter: Int?

    init(failBefore: Int? = nil, failAfter: Int? = nil) {
        self.failBefore = failBefore
        self.failAfter = failAfter
    }

    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try data[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        if checkpoint.generation == failBefore { failBefore = nil; throw StoreFailure.unavailable }
        let encoded = try JSONEncoder().encode(checkpoint)
        data[checkpoint.executionID] = encoded
        history.append(try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: encoded))
        if checkpoint.generation == failAfter { failAfter = nil; throw StoreFailure.unavailable }
    }

    func latest() throws -> WorkflowExecutionCheckpoint { try #require(history.last) }
    var saves: [WorkflowExecutionCheckpoint] { history }
}

private func paused(_ outcome: WorkflowExecutionOutcome) throws -> WorkflowExecutionCheckpoint {
    guard case .awaitingApproval(let checkpoint) = outcome else { throw RecoveryError.invalidCheckpoint("expected approval") }
    return checkpoint
}

private func completed(_ outcome: WorkflowExecutionOutcome) throws -> WorkflowExecutionReport {
    guard case .completed(let report) = outcome else { throw RecoveryError.invalidCheckpoint("expected completion") }
    return report
}

@Suite struct RecoveryTests {
    @Test func executionIdentityIsDistinctFromDefinitionAndStableAcrossResume() async throws {
        let workflow = Workflow("Reusable definition") {
            Step.template("gate", "approved").requiringApproval("Review")
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        let first = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        let data = try JSONEncoder().encode(first)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["executionID"] as? String)?.uppercased() == first.executionID.uuidString)
        #expect(json["runID"] == nil)
        #expect(first.workflowID == workflow.id)

        let restored = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: data)
        _ = try completed(await executor.resume(workflow, from: restored, revision: "1", approval: .approve, store: store))
        let confirmed = try await store.latest()
        #expect(confirmed.executionID == first.executionID)
        #expect(confirmed.workflowID == workflow.id)
        let second = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        #expect(second.executionID != first.executionID)
        #expect(second.workflowID == first.workflowID)
    }

    @Test func previousCheckpointIdentityKeyIsNotSilentlyAccepted() async throws {
        let workflow = Workflow("No legacy alias") { Step.template("gate", "ok").requiringApproval("Review") }
        let store = MemoryCheckpoints()
        let checkpoint = try paused(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        json["runID"] = json.removeValue(forKey: "executionID")
        let previous = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: previous) }
    }

    @Test func recreatedCustomBodiesResumeWithoutSerializingOrRepeatingCode() async throws {
        let id = UUID()
        let before = Mutex(0)
        let after = Mutex(0)
        func workflow() -> Workflow {
            Workflow("Compile in the app", id: id) {
                Step.custom("first") { context in before.withLock { $0 += 1 }; return .text(context.input.textValue + " one") }
                Step.custom("second") { context in after.withLock { $0 += 1 }; return .text(context["first"]!.textValue + " two") }
                    .requiringApproval("Review the draft")
            }
        }
        let store = MemoryCheckpoints()
        let first = workflow()
        let gate = try paused(await WorkflowExecutor().start(first, input: .text("start"), revision: "v1", store: store))
        #expect(gate.step == "second")
        #expect(gate.approval == "Review the draft")
        #expect(before.withLock { $0 } == 1)
        #expect(after.withLock { $0 } == 0)
        #expect(gate.input == .text("start"))
        #expect(gate.results["first"] == .text("start one"))
        #expect(gate.records.map(\.step) == ["first"])
        #expect(throws: (any Error).self) { try JSONEncoder().encode(first) }
        let report = try completed(await WorkflowExecutor().resume(workflow(), from: gate, revision: "v1", approval: .approve, store: store))
        #expect(report.output == .text("start one two"))
        #expect(report.records.map(\.step) == ["first", "second"])
        #expect(before.withLock { $0 } == 1)
        #expect(after.withLock { $0 } == 1)
        let saves = await store.saves
        #expect(saves.map(\.generation) == Array(0..<saves.count))
        #expect(saves.last?.status == .completed)
    }

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

    @Test func eachGateNeedsItsOwnApprovalAndCallbacksDoNotReplay() async throws {
        let store = MemoryCheckpoints()
        let observed = Mutex<[String]>([])
        let workflow = Workflow("Two gates") {
            Step.template("first", "one").requiringApproval("First")
            Step.template("second", "two").requiringApproval("Second")
        }
        let executor = WorkflowExecutor()
        let first = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        let second = try paused(await executor.resume(workflow, from: first, revision: "1", approval: .approve, store: store,
                                                   onStep: { record in observed.withLock { $0.append(record.step) } }))
        #expect(second.step == "second")
        _ = try completed(await executor.resume(workflow, from: second, revision: "1", approval: .approve, store: store,
                                             onStep: { record in observed.withLock { $0.append(record.step) } }))
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
        guard case .rejected(let rejected) = try await executor.resume(workflow, from: gate, revision: "1", approval: .reject, store: store) else {
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

    @Test func concurrentResumesClaimAStepOnlyOnce() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Race") {
            Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .text("done") }.requiringApproval("Confirm")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await WorkflowExecutor().resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
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
            try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
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
        await #expect(throws: StoreFailure.self) { try await executor.start(workflow, input: .null, revision: "1", store: store) }
        let interrupted = try await store.latest()
        #expect(interrupted.status == .running)
        await #expect(throws: RecoveryError.interrupted(step: "create")) {
            try await executor.resume(workflow, from: interrupted, revision: "1", store: store)
        }
        // The caller verified the remote object independently. No request occurs.
        let ready = try await executor.confirmCompletion(interrupted, in: workflow, revision: "1",
                                                       value: .dictionary(["id": .number(7)]), store: store)
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
        await #expect(throws: StoreFailure.self) {
            try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
        }
        let checkpoint = try await store.latest()
        #expect(checkpoint.status == .completed)
        let report = try completed(await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store))
        #expect(report.output == .text("done"))
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

    @Test func definitionRevisionAndToolKitChangesRejectStaleCheckpoints() async throws {
        let workflow = Workflow("Definition") { Step.template("gate", "one").requiringApproval("Check") }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        var changed = workflow
        changed.steps[0].kind = .template("two")
        await #expect(throws: RecoveryError.definitionChanged) {
            try await WorkflowExecutor().resume(changed, from: gate, revision: "1", approval: .approve, store: store)
        }
        await #expect(throws: RecoveryError.revisionMismatch) {
            try await WorkflowExecutor().resume(workflow, from: gate, revision: "2", approval: .approve, store: store)
        }
        let kit = ToolKit(id: "new", name: "New", summary: "Different tools", tools: [])
        await #expect(throws: RecoveryError.definitionChanged) {
            try await WorkflowExecutor(toolKits: [kit]).resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(await store.saves.count == 2)
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

    @Test func restoredRunPolicyCannotBeRelaxedByANewRunner() async throws {
        let workflow = Workflow("Read only") {
            Step.request("write", HTTPRequest(.post, url: "https://example.test/write")).requiringApproval("Check")
        }
        let store = MemoryCheckpoints()
        let server = FakeServer(json: "{}")
        let gate = try paused(await WorkflowExecutor(policy: .readOnly).start(workflow, input: .null, revision: "1", store: store))
        await #expect(throws: (any Error).self) {
            try await WorkflowExecutor(requests: server, writePolicy: .allow).resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func labelsSurviveJSONResumeAndBlockRemoteInferenceBeforeFactory() async throws {
        let model = ScriptedModel("remote", replies: ["must not run"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("remote", location: .remote) { loads.withLock { $0 += 1 }; return model }
        let workflow = Workflow("Private values") {
            Step.template("private", "PRIVATE").withPolicy(.localOnly)
            Step.prompt("cloud", "Read {{private}}", model: "remote").requiringApproval("Review")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor(catalog: catalog).start(workflow, input: .text("PUBLIC"), revision: "1", store: store))
        await #expect(throws: (any Error).self) {
            try await WorkflowExecutor(catalog: catalog).resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func nativeHistoryAndNewToolWrappersRestoreWithoutReplayingCallsOrSecrets() async throws {
        let server = FakeServer(json: #"{"found":"MATCH"}"#)
        let first = ScriptedModel("model", replies: [#"<tool:lookup>{}"#, "FIRST_REPLY"])
        let second = ScriptedModel("model", replies: [#"<tool:lookup>{}"#, "SECOND_REPLY"])
        let token = "key-never-store-123"
        let tool1 = AgentTool(name: "lookup", description: "First lookup", request: HTTPRequest(url: "https://example.test/first",
            headers: [.init("Authorization", "Bearer {{secret.KEY}}")]))
        let tool2 = AgentTool(name: "lookup", description: "Second lookup", request: HTTPRequest(url: "https://example.test/second"))
        let workflow = Workflow("History") {
            Step.agent("first", "FIRST_TASK", tools: [tool1], model: "model").withContext(.conversation("writer"))
            Step.agent("second", "SECOND_TASK", tools: [tool2], input: "input", model: "model")
                .withContext(.conversation("writer")).requiringApproval("Continue")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor(catalog: .scripted(["model": first]), requests: server,
            secrets: FakeSecrets(values: ["KEY": token])).start(workflow, input: .text("INPUT"), revision: "1", store: store))
        let json = String(decoding: try JSONEncoder().encode(gate), as: UTF8.self)
        #expect(json.contains("FIRST_REPLY"))
        #expect(!json.contains(token))
        let report = try completed(await WorkflowExecutor(catalog: .scripted(["model": second]), requests: server)
            .resume(workflow, from: gate, revision: "1", approval: .approve, store: store))
        #expect(report.output == .text("SECOND_REPLY"))
        #expect(first.callCount == 2)
        #expect(second.callCount == 2)
        #expect(server.requests.map { $0.url.path } == ["/first", "/second"])
        let history = String(decoding: try JSONEncoder().encode(second.histories[0]), as: UTF8.self)
        #expect(history.contains("FIRST_REPLY"))
        #expect(history.contains("MATCH"))
        #expect(report.records.map(\.toolCalls) == [["lookup"], ["lookup"]])
    }

    @Test func restoredConversationPrivacyStillAppliesIfHostChangesModelLocality() async throws {
        let local = ScriptedModel("model", replies: ["PRIVATE_REPLY"])
        let remote = ScriptedModel("model", replies: ["must not run"])
        let loads = Mutex(0)
        let workflow = Workflow("Private history") {
            Step.prompt("first", "PRIVATE_TASK", model: "model").withContext(.conversation("same")).withPolicy(.localOnly)
            Step.prompt("second", "PUBLIC_TASK", input: "input", model: "model")
                .withContext(.conversation("same")).requiringApproval("Continue")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor(catalog: ModelCatalog().registering("model", location: .local) { local })
            .start(workflow, input: .text("PUBLIC"), revision: "1", store: store))
        let catalog = ModelCatalog().registering("model", location: .remote) { loads.withLock { $0 += 1 }; return remote }
        await #expect(throws: (any Error).self) {
            try await WorkflowExecutor(catalog: catalog).resume(workflow, from: gate, revision: "1", approval: .approve, store: store)
        }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func completedBlocksRestoreExportedValuesWithoutReplayingTheirChildren() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Blocks") {
            Step.ifEquals("branch", reference: "input", value: "yes") {
                Step.template("selected", "chosen")
            }
            Step.parallel("both") {
                Step.custom("a") { _ in calls.withLock { $0 += 1 }; return .text("A") }
                Step.template("b", "B")
            }
            Step.template("output", "{{branch}} {{both.a}} {{a}} {{b}}").requiringApproval("Check")
        }
        let store = MemoryCheckpoints()
        let gate = try paused(await WorkflowExecutor().start(workflow, input: .text("yes"), revision: "1", store: store))
        let report = try completed(await WorkflowExecutor().resume(workflow, from: gate, revision: "1", approval: .approve, store: store))
        #expect(report.output == .text("chosen A A B"))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func interruptedBlockCannotBeReplayedOrReconciledWithJustOneValue() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Atomic block") {
            Step.parallel("block") {
                Step.custom("effect") { _ in calls.withLock { $0 += 1 }; return .text("A") }
                Step.template("other", "B")
            }
        }
        let store = MemoryCheckpoints(failBefore: 2)
        let executor = WorkflowExecutor()
        await #expect(throws: StoreFailure.self) { try await executor.start(workflow, input: .null, revision: "1", store: store) }
        let checkpoint = try await store.latest()
        await #expect(throws: RecoveryError.interrupted(step: "block")) {
            try await executor.resume(workflow, from: checkpoint, revision: "1", store: store)
        }
        await #expect(throws: (any Error).self) {
            try await executor.confirmCompletion(checkpoint, in: workflow, revision: "1", value: .null, store: store)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func invalidPositionAndDuplicateHistoryFailBeforeIndexingOrFactories() async throws {
        let workflow = Workflow("Validate") { Step.template("gate", "ok").requiringApproval("Check") }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        let gate = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        var invalid = gate
        invalid.nextStep = -1
        await #expect(throws: (any Error).self) { try await executor.resume(workflow, from: invalid, revision: "1", store: store) }
        invalid = gate
        invalid.state.conversations = Array(repeating: CheckpointConversation(name: "same", model: "model", transcript: Transcript(), data: .unrestricted), count: 2)
        await #expect(throws: (any Error).self) { try await executor.resume(workflow, from: invalid, revision: "1", store: store) }
    }

    @Test func emptyWorkflowAndNamedOutputSurviveCompletedResume() async throws {
        let empty = Workflow("Empty") {}
        let emptyStore = MemoryCheckpoints()
        let report = try completed(await WorkflowExecutor().start(empty, input: .text("input"), revision: "1", store: emptyStore))
        #expect(report.output == .text("input"))
        let workflow = Workflow("Selected", output: "first") {
            Step.template("first", "private").withPolicy(.localOnly)
            Step.template("last", "public", input: "input")
        }
        let store = MemoryCheckpoints()
        let initial = try completed(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        let checkpoint = try await store.latest()
        let restored = try completed(await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store))
        #expect(restored.output == .text("private"))
        #expect(restored.outputDataAccess == .localOnly)
        #expect(restored.records == initial.records)
        #expect(restored.duration == initial.duration)
    }

    @Test func reconciliationCannotRemovePrivateLabels() async throws {
        let workflow = Workflow("Private interrupted work") {
            Step.template("private", "PRIVATE").withPolicy(.localOnly)
            Step.custom("effect") { _ in throw CancellationError() }
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        await #expect(throws: CancellationError.self) { try await executor.start(workflow, input: .null, revision: "1", store: store) }
        let interrupted = try await store.latest()
        let checkpoint = try await executor.confirmCompletion(interrupted, in: workflow, revision: "1", value: .text("verified"), store: store)
        #expect(checkpoint.resultDataAccess["effect"] == .localOnly)
        let report = try completed(await executor.resume(workflow, from: checkpoint, revision: "1", store: store))
        #expect(report.outputDataAccess == .localOnly)
    }

    @Test func newerPolicyCanNarrowEvenAnAlreadyCompletedReport() async throws {
        let workflow = Workflow("Public") { Step.template("value", "public") }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        _ = try await executor.start(workflow, input: .null, revision: "1", store: store)
        let checkpoint = try await store.latest()
        let report = try completed(await executor.resume(workflow, from: checkpoint, revision: "1", policy: .localOnly, store: store))
        #expect(report.outputDataAccess == .localOnly)
    }

    @Test func approvalsRoundTripAndOldStepJSONRemainsCompatible() throws {
        let step = Step.template("value", "text").requiringApproval("Check")
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
        let old = Data(#"{"name":"value","kind":{"template":{"_0":"text"}}}"#.utf8)
        #expect(try JSONDecoder().decode(Step.self, from: old).approval == nil)
    }
}
