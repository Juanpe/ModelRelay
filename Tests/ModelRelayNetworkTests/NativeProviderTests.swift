import AnyLanguageModel
import Foundation
import ModelRelay
import Synchronization
import Testing

/// A fully local HTTP transport used by the real AnyLanguageModel providers.
private final class ProviderStub: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        var url: URL
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }
    struct State: Sendable {
        var replies: [(Int, String)] = []
        var sent: [Sent] = []
    }
    static let state = Mutex(State())

    static func reset(_ replies: [(Int, String)]) { state.withLock { $0 = State(replies: replies) } }
    static var sent: [Sent] { state.withLock { $0.sent } }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStub.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let bodyData = body
        let reply = Self.state.withLock { state in
            state.sent.append(Sent(url: request.url!, body: bodyData))
            return state.replies.isEmpty ? (599, "Unscripted request") : state.replies.removeFirst()
        }
        let streaming = ((try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any])?["stream"] as? Bool == true
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                                       headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (streaming ? ProviderStreamFixture.data(from: Data(reply.1.utf8)) : Data(reply.1.utf8)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ToolServer: RequestPerformer {
    private(set) var requests: [PreparedRequest] = []
    func perform(_ request: PreparedRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, body: Data(#"{"id":"task-1"}"#.utf8))
    }
}

private struct Secrets: SecretProvider {
    func secret(named name: String) async throws -> String? { "host-secret-not-for-the-model" }
}

private actor ProviderCheckpoints: WorkflowExecutionCheckpointStore {
    private var saved: [UUID: Data] = [:]
    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try saved[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        saved[checkpoint.executionID] = try JSONEncoder().encode(checkpoint)
    }
}

@Suite(.serialized) struct NativeProviderTests {
    private func catalog() -> ModelCatalog {
        let model = OpenAILanguageModel(baseURL: URL(string: "https://provider.test/v1/")!, apiKey: "test-only",
                                       model: "scripted", session: ProviderStub.session())
        return ModelCatalog().registering("provider") { model }
    }

    private func anthropicCatalog() -> ModelCatalog {
        let model = AnthropicLanguageModel(baseURL: URL(string: "https://anthropic.test/")!, apiKey: "test-only",
                                          model: "scripted", session: ProviderStub.session())
        return ModelCatalog().registering("provider") { model }
    }

    private func reply(_ text: String) throws -> (Int, String) {
        let body: [String: Any] = ["id": "chat-test", "object": "chat.completion", "created": 0, "model": "scripted",
            "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
        return (200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
    }

    private var toolReply: (Int, String) {
        (200, #"{"id":"chat-test","object":"chat.completion","created":0,"model":"scripted","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"create_task","arguments":"{\"title\":\"Read article\"}"}}]}}]}"#)
    }

    private let createTask = AgentTool(name: "create_task", description: "Create one task.", parameters: [Field("title", .text)],
        request: HTTPRequest(.post, url: "https://tasks.test/tasks", headers: [.init("Authorization", "Bearer {{secret.KEY}}")],
                             body: #"{"title":"{{args.title}}"}"#))

    @Test func textUsesTheRealProviderAndOnlyOnePrompt() async throws {
        ProviderStub.reset([try reply("A short summary.")])
        let workflow = Workflow("Summarize") {
            Step.prompt("summary", "Summarize this article.", model: "provider")
            Step.template("result", "Summary: {{summary}}")
        }
        let report = try await WorkflowExecutor(catalog: catalog()).run(workflow, input: .text("Article text"))
        #expect(report.output == .text("Summary: A short summary."))
        #expect(report.records.first?.model == "provider")
        let sent = try #require(ProviderStub.sent.first)
        #expect(sent.url.path == "/v1/chat/completions")
        let messages = try #require(sent.json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks.compactMap { $0["text"] as? String }.joined() == "Summarize this article.\n\nInput:\nArticle text")
    }

    @Test func extractionKeepsDynamicFieldTypesAndTheSchema() async throws {
        ProviderStub.reset([try reply(#"{"merchant":"Coffee","total":8.3,"paid":true,"currency":"EUR","items":["latte"]}"#)])
        let workflow = Workflow("Receipt") {
            Step.extract("expense", instruction: "Extract the expense.", model: "provider") {
                Field("merchant", .text)
                Field("total", .number)
                Field("paid", .bool)
                Field("currency", .choice(["EUR", "USD"]))
                Field("items", .list(.text))
            }
        }
        let report = try await WorkflowExecutor(catalog: catalog()).run(workflow, input: .text("Receipt"))
        #expect(report.output["total"] == .number(8.3))
        #expect(report.output["paid"] == .bool(true))
        #expect(report.output["items"] == .list([.text("latte")]))
        let format = try #require(ProviderStub.sent.first?.json["response_format"] as? [String: Any])
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?.keys.sorted() == ["currency", "items", "merchant", "paid", "total"])
    }

    @Test func classifyUnwrapsAScalarSchema() async throws {
        ProviderStub.reset([try reply(#"{"response":"urgent"}"#)])
        let workflow = Workflow("Route") {
            Step.classify("kind", "Urgent?", labels: ["urgent", "later"], model: "provider")
            Step.ifEquals("route", reference: "kind", value: "urgent") {
                Step.template("action", "Review {{input}}")
            }
        }
        let report = try await WorkflowExecutor(catalog: catalog()).run(workflow, input: .text("Server down"))
        #expect(report.output == .text("Review Server down"))
    }

    @Test func toolsRunOnceThroughTheHostAndReturnToTheProvider() async throws {
        ProviderStub.reset([toolReply, try reply("Created task-1.")])
        let server = ToolServer()
        let approvals = Mutex(0)
        let executor = WorkflowExecutor(catalog: catalog(), requests: server, secrets: Secrets(), writePolicy: .ask { _ in
            approvals.withLock { $0 += 1 }
            return true
        })
        let workflow = Workflow("Create") {
            Step.agent("answer", "Create a task.", tools: [createTask], model: "provider")
        }
        let report = try await executor.run(workflow, input: .text("Read article"))
        #expect(report.output == .text("Created task-1."))
        #expect(report.records.first?.toolCalls == ["create_task"])
        #expect(await server.requests.count == 1)
        #expect(approvals.withLock { $0 } == 1)
        #expect(ProviderStub.sent.count == 2)
        let messages = try #require(ProviderStub.sent.last?.json["messages"] as? [[String: Any]])
        #expect(messages.suffix(3).compactMap { $0["role"] as? String } == ["user", "assistant", "tool"])
        #expect(messages.filter { $0["role"] as? String == "user" }.count == 1)
        #expect(messages.last?["tool_call_id"] as? String == "call-1")
        #expect((messages.last?["content"] as? String)?.contains("task-1") == true)
        #expect(ProviderStub.sent.allSatisfy { !String(decoding: $0.body, as: UTF8.self).contains("host-secret-not-for-the-model") })
    }

    @Test func aDeniedWriteNeverReachesTheHost() async throws {
        ProviderStub.reset([toolReply])
        let server = ToolServer()
        let workflow = Workflow("Denied") {
            Step.agent("answer", "Create a task.", tools: [createTask], model: "provider")
        }
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor(catalog: catalog(), requests: server, secrets: Secrets()).run(workflow, input: .text("x"))
        }
        #expect(await server.requests.isEmpty)
        #expect(ProviderStub.sent.count == 1)
    }

    @Test func failureAfterAToolDoesNotReplayItOnFallback() async throws {
        ProviderStub.reset([toolReply, (500, #"{"error":{"message":"down"}}"#), try reply("Must not run")])
        let server = ToolServer()
        let workflow = Workflow("Failure") {
            Step.agent("answer", "Create a task.", tools: [createTask], model: "provider", fallback: "provider")
        }
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor(catalog: catalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
                .run(workflow, input: .text("x"))
        }
        #expect(await server.requests.count == 1)
        #expect(ProviderStub.sent.count == 2)
    }

    @Test func aProviderFailureBeforeAnyToolCanUseFallback() async throws {
        ProviderStub.reset([(503, #"{"error":{"message":"down"}}"#), try reply("Fallback answer")])
        let workflow = Workflow("Fallback") {
            Step.prompt("answer", "Answer.", model: "provider", fallback: "provider")
        }
        let report = try await WorkflowExecutor(catalog: catalog()).run(workflow, input: .text("x"))
        #expect(report.output == .text("Fallback answer"))
        #expect(report.records.first?.usedFallback == true)
        #expect(ProviderStub.sent.count == 2)
    }

    @Test func anthropicCanRunTextAndStructuredStepsInTheSameWorkflow() async throws {
        ProviderStub.reset([
            (200, #"{"id":"m1","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"A summary"}]}"#),
            (200, #"{"id":"m2","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"{\"total\":8.3}"}]}"#),
        ])
        let workflow = Workflow("Anthropic") {
            Step.prompt("summary", "Summarize.", model: "provider")
            Step.extract("expense", instruction: "Extract.", model: "provider") { Field("total", .number) }
        }
        let report = try await WorkflowExecutor(catalog: anthropicCatalog()).run(workflow, input: .text("Receipt"))
        #expect(report.records.first?.value == .text("A summary"))
        #expect(report.output["total"] == .number(8.3))
        #expect(ProviderStub.sent.count == 2)
        #expect(ProviderStub.sent.allSatisfy { $0.url.path == "/v1/messages" })
    }

    @Test func anthropicAlsoProposesToolsWithoutExecutingThemTwice() async throws {
        ProviderStub.reset([
            (200, #"{"id":"m1","type":"message","role":"assistant","model":"scripted","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call-1","name":"create_task","input":{"title":"Read article"}}]}"#),
            (200, #"{"id":"m2","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"Created"}]}"#),
        ])
        let server = ToolServer()
        let workflow = Workflow("Anthropic tool") {
            Step.agent("answer", "Create a task.", tools: [createTask], model: "provider")
        }
        let report = try await WorkflowExecutor(catalog: anthropicCatalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
            .run(workflow, input: .text("x"))
        #expect(report.output == .text("Created"))
        #expect(await server.requests.count == 1)
        #expect(ProviderStub.sent.count == 2)
        let messages = try #require(ProviderStub.sent.last?.json["messages"] as? [[String: Any]])
        let output = try #require((messages.last?["content"] as? [[String: Any]])?.first)
        #expect(output["type"] as? String == "tool_result")
        #expect(output["tool_use_id"] as? String == "call-1")
    }

    @Test func anthropicReasoningSignatureSurvivesTheNativeToolLoop() async throws {
        ProviderStub.reset([
            (200, #"{"id":"m1","type":"message","role":"assistant","model":"scripted","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"Plan","signature":"opaque"},{"type":"tool_use","id":"call-1","name":"create_task","input":{"title":"Read article"}}]}"#),
            (200, #"{"id":"m2","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"Created"}]}"#),
        ])
        let server = ToolServer()
        let workflow = Workflow("Native reasoning") { Step.agent("answer", "Create.", tools: [createTask], model: "provider") }
        let report = try await WorkflowExecutor(catalog: anthropicCatalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
            .run(workflow, input: .text("x"))
        #expect(report.output == .text("Created"))
        #expect(await server.requests.count == 1)
        let messages = try #require(ProviderStub.sent.last?.json["messages"] as? [[String: Any]])
        let blocks = try #require(messages.first(where: { $0["role"] as? String == "assistant" })?["content"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "thinking")
        #expect(blocks.first?["signature"] as? String == "opaque")
    }

    @Test func nativeConversationKeepsToolHistoryButReplacesCurrentTools() async throws {
        ProviderStub.reset([toolReply, try reply("Created task-1."), try reply("Reviewed task-1.")])
        let server = ToolServer()
        let workflow = Workflow("Two native turns") {
            Step.agent("create", "Create.", tools: [createTask], model: "provider").withContext(.conversation("assistant"))
            Step.agent("review", "Review only.", input: "input", model: "provider")
                .withContext(.conversation("assistant")).withPolicy(.readOnly)
        }
        let report = try await WorkflowExecutor(catalog: catalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
            .run(workflow, input: .text("Read article"))
        #expect(report.output == .text("Reviewed task-1."))
        #expect(await server.requests.count == 1)
        #expect(ProviderStub.sent.count == 3)
        let last = try #require(ProviderStub.sent.last)
        let messages = try #require(last.json["messages"] as? [[String: Any]])
        #expect(messages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call-1" })
        #expect(last.json["tools"] == nil)
    }

    @Test func anthropicReasoningAndToolHistorySurviveDurablePauseWithoutReplayingWrites() async throws {
        ProviderStub.reset([
            (200, #"{"id":"m1","type":"message","role":"assistant","model":"scripted","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"Plan","signature":"opaque"},{"type":"tool_use","id":"call-1","name":"create_task","input":{"title":"Read article"}}]}"#),
            (200, #"{"id":"m2","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"Created"}]}"#),
            (200, #"{"id":"m3","type":"message","role":"assistant","model":"scripted","stop_reason":"end_turn","content":[{"type":"text","text":"Reviewed"}]}"#),
        ])
        let workflow = Workflow("Recover native reasoning") {
            Step.agent("create", "Create.", tools: [createTask], model: "provider").withContext(.conversation("assistant"))
            Step.agent("review", "Review only.", input: "input", model: "provider")
                .withContext(.conversation("assistant")).requiringApproval("Review")
        }
        let server = ToolServer()
        let store = ProviderCheckpoints()
        let outcome = try await WorkflowExecutor(catalog: anthropicCatalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
            .start(workflow, input: .text("Read article"), revision: "1", store: store)
        guard case .awaitingApproval(let gate) = outcome else { Issue.record("expected pause"); return }
        let data = try JSONEncoder().encode(gate)
        #expect(!String(decoding: data, as: UTF8.self).contains("host-secret-not-for-the-model"))
        let restored = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: data)
        let resumed = try await WorkflowExecutor(catalog: anthropicCatalog(), requests: server)
            .resume(workflow, from: restored, revision: "1", approval: .approve, store: store)
        guard case .completed(let report) = resumed else { Issue.record("expected completion"); return }
        #expect(report.output == .text("Reviewed"))
        #expect(await server.requests.count == 1)
        #expect(ProviderStub.sent.count == 3)
        let last = try #require(ProviderStub.sent.last)
        let messages = try #require(last.json["messages"] as? [[String: Any]])
        let blocks = try #require(messages.first(where: { $0["role"] as? String == "assistant" })?["content"] as? [[String: Any]])
        #expect(blocks.first?["signature"] as? String == "opaque")
        #expect(messages.contains { message in
            (message["content"] as? [[String: Any]])?.contains { $0["tool_use_id"] as? String == "call-1" } == true
        })
        #expect(last.json["tools"] == nil)
    }

    @Test func theHostToolBudgetStillAppliesAcrossProviderRounds() async throws {
        ProviderStub.reset((1...8).map { index in
            (toolReply.0, toolReply.1.replacingOccurrences(of: "call-1", with: "call-\(index)").replacingOccurrences(of: "Read article", with: "Task \(index)"))
        })
        let server = ToolServer()
        let workflow = Workflow("Loop") {
            Step.agent("answer", "Create tasks.", tools: [createTask], model: "provider")
        }
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor(catalog: catalog(), requests: server, secrets: Secrets(), writePolicy: .allow)
                .run(workflow, input: .text("x"))
        }
        #expect(await server.requests.count == AgentTool.maxCallsPerStep)
        #expect(ProviderStub.sent.count == AgentTool.maxCallsPerStep + 1)
    }

}
