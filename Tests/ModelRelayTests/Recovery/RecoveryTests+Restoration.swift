import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

extension RecoveryTests {
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
        let gate = try paused(await WorkflowExecutor(
            catalog: .scripted(["model": first]),
            requests: server,
            secrets: FakeSecrets(values: ["KEY": token])
        ).start(workflow, input: .text("INPUT"), revision: "1", store: store))
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
}
