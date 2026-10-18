import Foundation
import Synchronization
import Testing
@testable import ModelRelay

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
            try await executor.execute(workflow, input: .null).observing(onEvent: { event in events.withLock { $0.append(event) } })
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
            _ = try await WorkflowExecutor(catalog: .scripted(["model": model])).execute(
                Workflow("Fail") { Step.prompt("ask", "PRIVATE_PROMPT", model: "model") }, input: .null)
                .observing(onStep: { record in records.withLock { $0.append(record) } })
            Issue.record("expected failure")
        } catch let RelayError.operationFailed(step, failure) {
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
        } catch let RelayError.operationFailed(_, failure) {
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
        } catch let RelayError.operationFailed(_, failure) {
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
        } catch let RelayError.operationFailed(_, failure) {
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
        } catch let RelayError.operationFailed(_, failure) {
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
        let report = try await WorkflowExecutor(
            catalog: .scripted(["primary": primary, "backup": backup]),
            requests: server,
            secrets: FakeSecrets(values: ["KEY": "SECRET_TOKEN"])
        )
        .execute(workflow, input: .text("PRIVATE_INPUT")).observing(onEvent: { event in events.withLock { $0.append(event) } })
        let all = events.withLock { $0 }
        #expect(all.first?.kind == .executionStarted)
        #expect(all.last?.kind == .executionCompleted)
        #expect(all.map(\.sequence) == Array(1 ... all.count))
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

    @Test func encodedCredentialsAreRedactedButOriginalHTTPStatusRemainsInspectable() async throws {
        let key = "key/a?b&c"
        let encoded = RequestBuilder.secretEncode(key)
        let server = FakeServer(status: 401, json: "{\"description\":\"Bad token \(encoded)\"}")
        let workflow = Workflow("Secret") { Step.request("fetch", HTTPRequest(url: "https://example.test/{{secret.KEY}}")) }
        let records = Mutex<[StepRecord]>([])
        do {
            _ = try await WorkflowExecutor(requests: server, secrets: FakeSecrets(values: ["KEY": key]))
                .execute(workflow, input: .null).observing(onStep: { record in records.withLock { $0.append(record) } })
            Issue.record("expected failure")
        } catch let RelayError.operationFailed(_, failure) {
            #expect(failure.info.category == .authenticationRequired)
            #expect((failure.rootCause as? HTTPResponseFailure)?.status == 401)
            #expect(!failure.info.message.contains(key) && !failure.info.message.contains(encoded))
            let json = String(decoding: try JSONEncoder().encode(records.withLock { $0 }), as: UTF8.self)
            #expect(!json.contains(key) && !json.contains(encoded))
        }
    }
}
