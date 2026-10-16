import Foundation
import Synchronization
import Testing
@testable import ModelRelay

private actor HardeningStore: WorkflowExecutionCheckpointStore {
    private var entries: [UUID: Data] = [:]
    private var saved: WorkflowExecutionCheckpoint?
    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try entries[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        let data = try JSONEncoder().encode(checkpoint)
        entries[checkpoint.executionID] = data
        saved = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: data)
    }
    func latest() throws -> WorkflowExecutionCheckpoint { try #require(saved) }
}

private enum HostProblem: Error, Equatable, WorkflowFailureClassifiable {
    case authentication, rejected
    var workflowFailureCategory: WorkflowFailureCategory { self == .authentication ? .authenticationRequired : .requestRejected }
}

private struct BrokenConnector: ToolServerConnector {
    func connect(to kit: ToolKit) async throws -> any ToolServerConnection { throw HostProblem.authentication }
}

private struct BrokenTransport: RequestPerformer {
    func perform(_ request: PreparedRequest) async throws -> HTTPResponse { throw HostProblem.rejected }
}

private final class CountedDecisions: DecisionModel {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
        count.withLock { $0 += 1 }
        return questions.map { Answer(name: $0.name, result: .yesNo(true)) }
    }
}

private actor ConcurrencyProbe {
    var active = 0
    var peak = 0
    var finished = 0
    func work() async throws -> Value {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(12))
        finished += 1
        return .text("done")
    }
}

@Suite struct ExecutionHardeningTests {
    @Test func preflightCollectsIssuesBeforeAnyBodyFactoryTransportOrEvent() async throws {
        let calls = Mutex(0)
        let model = ScriptedModel("model", replies: ["unused"])
        let catalog = ModelCatalog().registering("model") { calls.withLock { $0 += 1 }; return model }
        let server = FakeServer(json: "{}")
        let executor = WorkflowExecutor(catalog: catalog, requests: server, writePolicy: .allow)
        let workflow = Workflow("Invalid", output: "missingOutput") {
            Step.custom("first") { _ in calls.withLock { $0 += 1 }; return .null }
            Step.request("write", HTTPRequest(.post, url: "https://example.test/write"))
            Step.prompt("bad", "{{missing}}", model: "missingModel")
            Step.template("first", "duplicate")
        }
        let issues = await executor.validate(workflow)
        #expect(issues.contains { $0.kind == .duplicateName })
        #expect(issues.contains { $0.kind == .unknownModel })
        #expect(issues.contains { $0.step == "Output" })
        let events = Mutex<[WorkflowExecutionEvent]>([])
        await #expect(throws: WorkflowValidationError(issues: issues)) {
            try await executor.run(workflow, input: .null, onEvent: { event in events.withLock { $0.append(event) } })
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(server.requests.isEmpty)
        #expect(events.withLock { $0.isEmpty })
    }

    @Test func invalidExplicitOutputNeverReturnsTheLastValue() async {
        let workflow = Workflow("Bad output", output: "typo") { Step.template("last", "must not return") }
        await #expect(throws: WorkflowValidationError.self) { try await WorkflowExecutor().run(workflow, input: .null) }
    }

    @Test func dynamicMissingFieldFailsBeforeSendingRequest() async {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("Dynamic field") {
            Step.custom("object") { _ in .dictionary(["present": .text("value")]) }
            Step.request("send", HTTPRequest(.post, url: "https://example.test/send", body: "{{object.absent}}"))
        }
        await #expect(throws: RelayError.unknownReference("object.absent", step: "send")) {
            try await WorkflowExecutor(requests: server, writePolicy: .allow).run(workflow, input: .null)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func incompatibleModelAndInvalidFieldsArePreflightIssuesWithoutLoading() async {
        let model = ScriptedModel("blind", replies: [])
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering("blind") { model })
        let workflow = Workflow("Schema") {
            Step.readImage("image", model: "blind")
            Step.extract("object", instruction: "Extract", model: "blind") { Field("a", .text); Field("a", .choice([])) }
        }
        let issues = await executor.validate(workflow)
        #expect(issues.contains { $0.kind == .incompatibleModel })
        #expect(issues.filter { $0.kind == .invalidSchema }.count == 2)
        #expect(model.callCount == 0)
    }

    @Test func nativeModelFailureRetainsOriginalCauseAndSerializableSummary() async throws {
        let model = ScriptedModel("model", replies: [nil])
        let records = Mutex<[StepRecord]>([])
        do {
            _ = try await WorkflowExecutor(catalog: .scripted(["model": model])).run(
                Workflow("Fail") { Step.prompt("ask", "PRIVATE_PROMPT", model: "model") }, input: .null,
                onStep: { record in records.withLock { $0.append(record) } })
            Issue.record("expected failure")
        } catch RelayError.operationFailed(let step, let failure) {
            #expect(step == "ask")
            #expect(failure.rootCause is ScriptedModel.Failure)
            #expect(!failure.info.outcomeUncertain)
            let record = try #require(records.withLock { $0.last })
            #expect(record.failureInfo == failure.info)
            _ = try JSONEncoder().encode(record)
        }
    }

    @Test func connectorAuthenticationCauseSurvivesTheExecutorBoundary() async throws {
        let kit = ToolKit(id: "remote", name: "Remote", tools: [], server: ToolServer(url: "https://example.test/mcp"))
        let workflow = Workflow("Authenticate") { Step.useTool("lookup", kit: "remote", tool: "lookup") }
        do {
            _ = try await WorkflowExecutor(toolKits: [kit], toolServers: BrokenConnector()).run(workflow, input: .null)
            Issue.record("expected failure")
        } catch RelayError.operationFailed(_, let failure) {
            #expect(failure.info.category == .authenticationRequired)
            #expect(failure.rootCause as? HostProblem == .authentication)
            #expect(!failure.info.outcomeUncertain)
        }
    }

    @Test func failedWriteIsUncertainAndNeverAutomaticallyRetried() async throws {
        let workflow = Workflow("Write") { Step.request("send", HTTPRequest(.post, url: "https://example.test/write")) }
        do {
            _ = try await WorkflowExecutor(requests: BrokenTransport(), writePolicy: .allow).run(workflow, input: .null)
            Issue.record("expected failure")
        } catch RelayError.operationFailed(_, let failure) {
            #expect(failure.info.category == .requestRejected)
            #expect(failure.info.outcomeUncertain)
            #expect(failure.rootCause as? HostProblem == .rejected)
        }
    }

    @Test func nativeAgentWriteFailureRetainsUncertaintyAndOriginalCause() async throws {
        let model = ScriptedModel("model", replies: [#"<tool:write>{}"#])
        let fallback = ScriptedModel("backup", replies: ["must not run"])
        let tool = AgentTool(name: "write", description: "Write", request: HTTPRequest(.post, url: "https://example.test/write"))
        let workflow = Workflow("Agent write") { Step.agent("agent", "Write", tools: [tool], model: "model", fallback: "backup") }
        do {
            _ = try await WorkflowExecutor(catalog: .scripted(["model": model, "backup": fallback]), requests: BrokenTransport(), writePolicy: .allow)
                .run(workflow, input: .null)
            Issue.record("expected failure")
        } catch RelayError.operationFailed(_, let failure) {
            #expect(failure.info.outcomeUncertain)
            #expect(failure.info.category == .requestRejected)
            #expect(failure.rootCause as? HostProblem == .rejected)
            #expect(fallback.callCount == 0)
        }
    }

    @Test func modelFailureAfterASuccessfulWriteStillIndicatesPossibleSideEffects() async throws {
        let model = ScriptedModel("model", replies: [#"<tool:write>{}"#, nil])
        let fallback = ScriptedModel("backup", replies: ["must not run"])
        let server = FakeServer(json: "{}")
        let tool = AgentTool(name: "write", description: "Write", request: HTTPRequest(.post, url: "https://example.test/write"))
        do {
            _ = try await WorkflowExecutor(catalog: .scripted(["model": model, "backup": fallback]), requests: server, writePolicy: .allow)
                .run(Workflow("Post-write failure") { Step.agent("agent", "Write", tools: [tool], model: "model", fallback: "backup") }, input: .null)
            Issue.record("expected failure")
        } catch RelayError.operationFailed(_, let failure) {
            #expect(failure.info.outcomeUncertain)
            #expect(server.requests.count == 1)
            #expect(fallback.callCount == 0)
        }
    }

    @Test func eventOrderAndMetadataDoNotContainPromptsValuesArgumentsOrSecrets() async throws {
        let primary = ScriptedModel("primary", replies: [nil])
        let backup = ScriptedModel("backup", replies: ["PRIVATE_RESULT"])
        let server = FakeServer(json: #"{"result":"PRIVATE_TOOL_RESULT"}"#)
        let events = Mutex<[WorkflowExecutionEvent]>([])
        let workflow = Workflow("Events") {
            Step.prompt("answer", "PRIVATE_PROMPT", model: "primary", fallback: "backup")
            Step.request("fetch", HTTPRequest(url: "https://example.test/?key={{secret.KEY}}"))
        }
        let report = try await WorkflowExecutor(catalog: .scripted(["primary": primary, "backup": backup]), requests: server,
            secrets: FakeSecrets(values: ["KEY": "SECRET_TOKEN"]))
            .run(workflow, input: .text("PRIVATE_INPUT"), onEvent: { event in events.withLock { $0.append(event) } })
        let all = events.withLock { $0 }
        #expect(all.first?.kind == .executionStarted)
        #expect(all.last?.kind == .executionCompleted)
        #expect(all.map(\.sequence) == Array(1...all.count))
        #expect(all.allSatisfy { $0.executionID == report.executionID && $0.workflowID == workflow.id })
        let kinds = all.map(\.kind)
        #expect(try #require(kinds.firstIndex(of: .modelFailed)) < #require(kinds.firstIndex(of: .fallbackSelected)))
        #expect(kinds.filter { $0 == .toolStarted }.count == 1)
        #expect(kinds.filter { $0 == .toolCompleted }.count == 1)
        let json = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        for text in ["PRIVATE_PROMPT", "PRIVATE_RESULT", "PRIVATE_INPUT", "PRIVATE_TOOL_RESULT", "SECRET_TOKEN", "https://"] {
            #expect(!json.contains(text))
        }
        #expect(report.usage.modelCalls == 2)
        #expect(report.usage.toolCalls == 1)
    }

    @Test func modelLimitStopsFallbackBeforeLoadingIt() async {
        let primary = ScriptedModel("primary", replies: [nil])
        let fallback = ScriptedModel("fallback", replies: ["unused"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("primary") { primary }.registering("fallback") { loads.withLock { $0 += 1 }; return fallback }
        let workflow = Workflow("Limited fallback") { Step.prompt("ask", "Q", model: "primary", fallback: "fallback") }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog, limits: .init(maxModelCalls: 1)).run(workflow, input: .null)
        }
        #expect(primary.callCount == 1)
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func zeroModelBudgetNeverLoadsAFactory() async {
        let loads = Mutex(0)
        let model = ScriptedModel("model", replies: ["unused"])
        let catalog = ModelCatalog().registering("model") { loads.withLock { $0 += 1 }; return model }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog).run(Workflow("Zero") { Step.prompt("ask", "Q", model: "model") },
                input: .null, limits: .init(maxModelCalls: 0))
        }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func toolLimitCoversDirectRequestsAndNativeAgentCallsTogether() async {
        let model = ScriptedModel("model", replies: [#"<tool:lookup>{}"#, "unused"])
        let server = FakeServer(json: "{}")
        let tool = AgentTool(name: "lookup", description: "Look up", request: HTTPRequest(url: "https://example.test/tool"))
        let workflow = Workflow("Tools") {
            Step.request("first", HTTPRequest(url: "https://example.test/direct"))
            Step.agent("second", "Find", tools: [tool], model: "model")
        }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(catalog: .scripted(["model": model]), requests: server)
                .run(workflow, input: .null, limits: .init(maxToolCalls: 1))
        }
        #expect(server.requests.count == 1)
    }

    @Test func parallelBranchesShareAnAtomicToolBudget() async {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("Parallel tools") {
            Step.parallel("both") {
                for index in 0..<12 { Step.request("call\(index)", HTTPRequest(url: "https://example.test/\(index)")) }
            }
        }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(requests: server).run(workflow, input: .null, limits: .init(maxToolCalls: 3))
        }
        #expect(server.requests.count <= 3)
    }

    @Test func nestedParallelBlocksRespectLeafConcurrencyWithoutDeadlock() async throws {
        let probe = ConcurrencyProbe()
        let workflow = Workflow("Nested concurrency") {
            Step.parallel("outer") {
                for branch in 0..<3 {
                    Step.parallel("branch\(branch)") {
                        for index in 0..<3 { Step.custom("leaf\(branch)_\(index)") { _ in try await probe.work() } }
                    }
                }
            }
        }
        _ = try await WorkflowExecutor().run(workflow, input: .null, limits: .init(maxDuration: .seconds(2), maxConcurrentSteps: 2))
        #expect(await probe.peak == 2)
        #expect(await probe.finished == 9)
    }

    @Test func totalDeadlineCancelsAnInflightNativeModelWithoutFallback() async {
        let primary = ScriptedModel("primary", replies: ["<hang>"])
        let fallback = ScriptedModel("fallback", replies: ["unused"])
        let events = Mutex<[WorkflowExecutionEvent]>([])
        let workflow = Workflow("Deadline") { Step.prompt("ask", "Q", model: "primary", fallback: "fallback") }
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor(catalog: .scripted(["primary": primary, "fallback": fallback]))
                .run(workflow, input: .null, limits: .init(maxDuration: .milliseconds(40)),
                     onEvent: { event in events.withLock { $0.append(event) } })
        }
        #expect(fallback.callCount == 0)
        #expect(events.withLock { $0.contains { $0.kind == .limitReached && $0.limit == .duration } })
        #expect(events.withLock { $0.last?.kind } == .executionFailed)
    }

    @Test func durationBudgetIncludesCustomBodiesAndCancelsQueuedLeaves() async {
        let workflow = Workflow("Queued work") {
            Step.parallel("block") {
                for index in 0..<20 {
                    Step.custom("slow\(index)") { _ in try await Task.sleep(for: .seconds(1)); return .null }
                }
            }
        }
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().run(workflow, input: .null, limits: .init(maxDuration: .milliseconds(25), maxConcurrentSteps: 1))
        }
    }

    @Test func executorLimitsCannotBeRelaxedAndCountersAreNotSharedAcrossRuns() async throws {
        let model = ScriptedModel("model", replies: ["one", "two", "three", "must not run"])
        let executor = WorkflowExecutor(catalog: .scripted(["model": model]), limits: .init(maxModelCalls: 1))
        let workflow = Workflow("One") { Step.prompt("ask", "Q", model: "model") }
        let first = try await executor.run(workflow, input: .null, limits: .init(maxModelCalls: 100))
        let second = try await executor.run(workflow, input: .null)
        #expect(first.usage.modelCalls == 1 && second.usage.modelCalls == 1)
        #expect(first.executionID != second.executionID)
        let twice = Workflow("Two") {
            Step.prompt("first", "Q", model: "model")
            Step.prompt("second", "Q", model: "model")
        }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await executor.run(twice, input: .null, limits: .init(maxModelCalls: 100))
        }
        #expect(model.callCount == 3)
    }

    @Test func invalidLimitsFailBeforeWork() async {
        let calls = Mutex(0)
        let workflow = Workflow("Invalid limits") { Step.custom("body") { _ in calls.withLock { $0 += 1 }; return .null } }
        for limits in [WorkflowExecutionLimits(maxModelCalls: -1), .init(maxToolCalls: -1), .init(maxConcurrentSteps: 0), .init(maxDuration: .seconds(-1))] {
            await #expect(throws: RelayError.invalidLimits) { try await WorkflowExecutor(limits: limits).run(workflow, input: .null) }
        }
        #expect(calls.withLock { $0 } == 0)
    }

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
            .start(workflow, input: .null, revision: "1", store: store, onEvent: { event in events.withLock { $0.append(event) } })
        guard case .awaitingApproval(let checkpoint) = outcome else { Issue.record("expected pause"); return }
        #expect(checkpoint.usage.modelCalls == 1)
        #expect(checkpoint.limits.maxModelCalls == 1)
        #expect(events.withLock { $0.last?.kind } == .approvalRequired)
        let oldInvocation = events.withLock { $0.first?.invocationID }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog).resume(workflow, from: checkpoint, revision: "1", approval: .approve,
                store: store, limits: .init(maxModelCalls: 99), onEvent: { event in events.withLock { $0.append(event) } })
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
        let pending = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store,
            onEvent: { event in events.withLock { $0.append(event) } })
        guard case .awaitingApproval(let checkpoint) = pending else { Issue.record("expected pause"); return }
        #expect(events.withLock { $0.map(\.kind) } == [.executionStarted, .checkpointSaved, .checkpointSaved, .approvalRequired])
        _ = try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", approval: .reject, store: store,
            onEvent: { event in events.withLock { $0.append(event) } })
        #expect(events.withLock { $0.last?.kind } == .approvalRejected)
        #expect(events.withLock { !$0.contains { $0.kind == .stepStarted } })
    }

    @Test func decisionModelsUseTheSameGlobalModelBudget() async {
        let model = CountedDecisions()
        let workflow = Workflow("Decisions") {
            Step.decide("first", questions: [Question("yes", "Yes?", .yesNo)], model: "decision")
            Step.decide("second", questions: [Question("yes", "Yes?", .yesNo)], model: "decision")
        }
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering(decisions: "decision") { model })
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await executor.run(workflow, input: .null, limits: .init(maxModelCalls: 1))
        }
        #expect(model.calls == 1)
    }

    @Test func consumedDurationSurvivesPauseAndCannotBeResetOnResume() async throws {
        let calls = Mutex(0)
        let workflow = Workflow("Time across pause") {
            Step.custom("first") { _ in try await Task.sleep(for: .milliseconds(20)); return .null }
            Step.custom("second") { _ in calls.withLock { $0 += 1 }; return .null }.requiringApproval("Review")
        }
        let store = HardeningStore()
        let result = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
        guard case .awaitingApproval(let checkpoint) = result else { Issue.record("expected pause"); return }
        let shorter = checkpoint.state.duration - .milliseconds(1)
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", approval: .approve,
                store: store, limits: .init(maxDuration: shorter))
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func narrowingLimitsAtAPendingApprovalPersistsANewGeneration() async throws {
        let workflow = Workflow("Narrow pending") { Step.template("gate", "ok").requiringApproval("Review") }
        let store = HardeningStore()
        let first = try await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store)
        guard case .awaitingApproval(let checkpoint) = first else { Issue.record("expected pause"); return }
        _ = try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store, limits: .init(maxToolCalls: 0))
        let saved = try await store.latest()
        #expect(saved.generation == checkpoint.generation + 1)
        #expect(saved.limits.maxToolCalls == 0)
        await #expect(throws: RecoveryError.checkpointConflict) {
            try await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", approval: .approve, store: store)
        }
    }

    @Test func encodedCredentialsAreRedactedButOriginalHTTPStatusRemainsInspectable() async throws {
        let key = "key/a?b&c"
        let encoded = RequestBuilder.secretEncode(key)
        let server = FakeServer(status: 401, json: "{\"description\":\"Bad token \(encoded)\"}")
        let workflow = Workflow("Secret") { Step.request("fetch", HTTPRequest(url: "https://example.test/{{secret.KEY}}")) }
        let records = Mutex<[StepRecord]>([])
        do {
            _ = try await WorkflowExecutor(requests: server, secrets: FakeSecrets(values: ["KEY": key]))
                .run(workflow, input: .null, onStep: { record in records.withLock { $0.append(record) } })
            Issue.record("expected failure")
        } catch RelayError.operationFailed(_, let failure) {
            #expect(failure.info.category == .authenticationRequired)
            #expect((failure.rootCause as? HTTPResponseFailure)?.status == 401)
            #expect(!failure.info.message.contains(key) && !failure.info.message.contains(encoded))
            let json = String(decoding: try JSONEncoder().encode(records.withLock { $0 }), as: UTF8.self)
            #expect(!json.contains(key) && !json.contains(encoded))
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
        let ready = try await WorkflowExecutor().confirmCompletion(checkpoint, in: workflow, revision: "1", value: .text("verified"),
            elapsed: .seconds(2), store: store)
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().resume(workflow, from: ready, revision: "1", store: store, limits: .init(maxDuration: .seconds(99)))
        }
    }
}
