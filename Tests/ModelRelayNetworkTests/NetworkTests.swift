import AnyLanguageModel
import Foundation
import Synchronization
import Testing
import ModelRelay
import ModelRelayHTTP
@testable import ModelRelayCloud

/// Answers every URLSession request locally with a scripted reply and keeps
/// what was sent. Nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
    /// Replies used in order before falling back to `reply`.
    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var sent: [Sent] = []
    /// Response headers for the queued replies, in the same order.
    nonisolated(unsafe) static var headerQueue: [[String: String]] = []

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.sent.append(Sent(url: request.url!, method: request.httpMethod ?? "GET",
                              headers: request.allHTTPHeaderFields ?? [:],
                              body: body))
        let next = Self.queue.isEmpty ? Self.reply : Self.queue.removeFirst()
        var headers = Self.headerQueue.isEmpty ? [:] : Self.headerQueue.removeFirst()
        let streaming = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["stream"] as? Bool == true
        if streaming { headers["Content-Type"] = "text/event-stream" }
        else if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (streaming ? ProviderStreamFixture.data(from: Self.providerEnvelope(next.body)) : Self.providerEnvelope(next.body)))
        client?.urlProtocolDidFinishLoading(self)
    }

    // Fill the standard wire envelope around concise provider fixtures.
    private static func providerEnvelope(_ body: String) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return Data(body.utf8) }
        if var choices = json["choices"] as? [[String: Any]] {
            json["id"] = "chat-test"; json["object"] = "chat.completion"; json["created"] = 0; json["model"] = "scripted"
            for index in choices.indices {
                choices[index]["index"] = index
                var message = choices[index]["message"] as? [String: Any] ?? [:]
                message["role"] = "assistant"
                choices[index]["message"] = message
                choices[index]["finish_reason"] = message["tool_calls"] == nil ? "stop" : "tool_calls"
            }
            json["choices"] = choices
        } else if json["content"] is [[String: Any]] {
            json["id"] = "message-test"; json["type"] = "message"; json["role"] = "assistant"; json["model"] = "scripted"
            if json["stop_reason"] == nil { json["stop_reason"] = "end_turn" }
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data(body.utf8)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct NetworkTests {
    init() {
        StubProtocol.sent = []
        StubProtocol.queue = []
        StubProtocol.headerQueue = []
        CloudHTTP.session.withLock { $0 = URLSession(configuration: StubProtocol.configuration()) }
    }

    private func receipt(model: ModelID) -> Workflow {
        Workflow(name: "Receipt", steps: [
            Step("expense", .extract(instruction: "Read the receipt.", fields: [Field("merchant", .text), Field("total", .number)]),
                 model: model),
        ])
    }

    @Test func urlSessionPerformerSendsTheRequest() async throws {
        StubProtocol.reply = (200, #"{"temp": 21}"#)
        let runner = WorkflowRunner(requests: URLSessionRequestPerformer(configuration: StubProtocol.configuration()),
                                    writePolicy: .allow)
        let workflow = Workflow(name: "Post", steps: [
            Step("post", .request(HTTPRequest(.post, url: "https://api.test/items", body: #"{"name": "{{input}}"}"#))),
        ])
        let report = try await runner.run(workflow, input: .text("Lisbon"))
        #expect(report.output["temp"] == .number(21))
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.method == "POST")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.json["name"] as? String == "Lisbon")
    }

    @Test func openAICompatibleExtractUsesAStrictSchema() async throws {
        StubProtocol.reply = (200, #"{"choices": [{"message": {"content": "{\"merchant\": \"Blue Bottle\", \"total\": 8.3}"}}]}"#)
        let model = OpenAILanguageModel(baseURL: URL(string: "https://llm.test/v1")!, apiKey: "sk-test", model: "small", session: URLSession(configuration: StubProtocol.configuration()))
        let runner = WorkflowRunner(catalog: ModelCatalog().registering("openai") { model })
        let report = try await runner.run(receipt(model: "openai"), input: .text("BLUE BOTTLE 8.30"))
        #expect(report.output["merchant"] == .text("Blue Bottle"))
        #expect(report.output["total"] == .number(8.3))

        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url.absoluteString == "https://llm.test/v1/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        let format = try #require(sent.json["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["strict"] as? Bool == true)
        #expect(((schema["schema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted() == ["merchant", "total"])
    }

    @Test func classifyLabelsAreWrappedAndUnwrapped() async throws {
        StubProtocol.reply = (200, #"{"choices": [{"message": {"content": "{\"response\": \"urgent\"}"}}]}"#)
        let runner = WorkflowRunner(catalog: ModelCatalog().registering("local", supportsImages: true) {
            OpenAILanguageModel(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "llama3.2", session: URLSession(configuration: StubProtocol.configuration()))
        })
        let workflow = Workflow(name: "Triage", steps: [
            Step("label", .classify(instruction: "Urgent?", labels: ["urgent", "later"]), model: "local"),
        ])
        let report = try await runner.run(workflow, input: .text("Server down"))
        #expect(report.output == .text("urgent"))
        #expect(StubProtocol.sent.count == 1)
    }

    @Test func claudeExtractUsesNativeStructuredOutput() async throws {
        StubProtocol.reply = (200, #"{"content": [{"type": "text", "text": "{\"merchant\":\"Blue Bottle\",\"total\":8.3}"}]}"#)
        let runner = WorkflowRunner(catalog: ModelCatalog().registering("claude", supportsImages: true) {
            AnthropicLanguageModel(apiKey: "sk-ant-test", model: "claude-haiku-5-5", session: URLSession(configuration: StubProtocol.configuration()))
        })
        let report = try await runner.run(receipt(model: "claude"), input: .text("BLUE BOTTLE 8.30"))
        #expect(report.output["total"] == .number(8.3))

        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.json["output_config"] != nil)
    }

    @Test func claudeTextAndErrorsWithoutTheKey() async throws {
        StubProtocol.reply = (200, #"{"content": [{"type": "text", "text": "Hello there."}]}"#)
        let catalog = ModelCatalog().registering("claude", supportsImages: true) { AnthropicLanguageModel(apiKey: "sk-ant-test", model: "claude-haiku-5-5", session: URLSession(configuration: StubProtocol.configuration())) }
        let ask = Workflow(name: "Ask", steps: [Step("hi", .prompt(instruction: "Say hello."), model: "claude")])
        #expect(try await WorkflowRunner(catalog: catalog).run(ask, input: .text("")).output == .text("Hello there."))

        StubProtocol.reply = (401, #"{"error": {"message": "invalid x-api-key"}}"#)
        do {
            _ = try await WorkflowRunner(catalog: catalog).run(ask, input: .text(""))
            Issue.record("Expected a failure")
        } catch let RelayError.stepFailed(step, reason) {
            #expect(step == "hi")
            #expect(reason.contains("401"))
            #expect(!reason.contains("sk-ant-test"))
        }
    }

    @Test func decisionsAPIAsksTypedQuestionsAndReadsProbabilities() async throws {
        StubProtocol.reply = (200, #"{"answers": [{"type": "predicate", "name": "damaged", "probability": 0.95}, {"type": "choice", "name": "queue", "choice": "shipping", "confidence": 0.81}, {"type": "score", "name": "urgency", "score": 1.3, "confidence": 0.62}]}"#)
        let model = DecisionsAPIModel(apiKey: "gw-test", zeroDataRetention: true)
        let answers = try await model.decide([
            Question("damaged", "Damaged?", .yesNo),
            Question("queue", "Which team?", .choice([.init("billing", description: "Refunds"), .init("shipping")])),
            Question("urgency", "How urgent?", .score(["low", "medium", "high"])),
        ], about: "Broken screen.")
        #expect(answers.map(\.result) == [.yesNo(true), .choice("shipping"), .score(1.3, level: "medium")])
        #expect(answers.first?.confidence == 0.95)

        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url.absoluteString == "https://ai-gateway.vercel.sh/v1/decisions")
        #expect(sent.headers["Authorization"] == "Bearer gw-test")
        #expect(sent.json["model"] as? String == "typesafe-ai/jev")
        let questions = try #require(sent.json["questions"] as? [[String: Any]])
        #expect(questions.map { $0["type"] as? String } == ["predicate", "choice", "score"])
        #expect(((sent.json["providerOptions"] as? [String: Any])?["gateway"] as? [String: Any])?["zeroDataRetention"] as? Bool == true)
        #expect(!String(describing: model).contains("gw-test"))
    }

    @Test func aRefusedQuestionFails() async throws {
        StubProtocol.reply = (200, #"{"answers": [{"type": "refusal", "name": "damaged"}]}"#)
        await #expect(throws: CloudModelError.self) {
            try await DecisionsAPIModel(apiKey: "k").decide([Question("damaged", "Damaged?", .yesNo)], about: "x")
        }
    }

    private struct WeatherAPI: RequestPerformer {
        func perform(_ request: PreparedRequest) async throws -> HTTPResponse {
            HTTPResponse(status: 200, body: Data(#"{"temp": 19}"#.utf8))
        }
    }

    private var weatherAgent: (ModelID) -> Workflow {
        { model in
            Workflow(name: "W", steps: [Step("answer", .agent(instruction: "Answer.", tools: [
                AgentTool(name: "getWeather", description: "Weather for a city.", parameters: [Field("city", .text)],
                          request: HTTPRequest(url: "https://weather.test/?q={{args.city}}")),
            ]), model: model)])
        }
    }

    @Test func openAICompatibleAgentsCallTools() async throws {
        StubProtocol.queue = [
            (200, #"{"choices": [{"message": {"content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "getWeather", "arguments": "{\"city\": \"Lisbon\"}"}}]}}]}"#),
            (200, #"{"choices": [{"message": {"content": "19 degrees in Lisbon."}}]}"#),
        ]
        let catalog = ModelCatalog().registering("ollama") {
            OpenAILanguageModel(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "qwen2.5", session: URLSession(configuration: StubProtocol.configuration()))
        }
        let report = try await WorkflowRunner(catalog: catalog, requests: WeatherAPI())
            .run(weatherAgent("ollama"), input: .text("Weather in Lisbon?"))
        #expect(report.output == .text("19 degrees in Lisbon."))
        #expect(report.records.first?.toolCalls == ["getWeather"])

        let first = try #require(StubProtocol.sent.first)
        let tools = try #require(first.json["tools"] as? [[String: Any]])
        #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "getWeather")
        let second = try #require(StubProtocol.sent.last?.json["messages"] as? [[String: Any]])
        #expect(second.contains { $0["role"] as? String == "assistant" && $0["tool_calls"] != nil })
        let result = try #require(second.last)
        #expect(result["role"] as? String == "tool")
        #expect(result["tool_call_id"] as? String == "call_1")
        #expect((result["content"] as? String)?.contains("19") == true)
    }

    @Test func claudeAgentsCallTools() async throws {
        StubProtocol.queue = [
            (200, #"{"content": [{"type": "tool_use", "id": "toolu_1", "name": "getWeather", "input": {"city": "Lisbon"}}], "stop_reason": "tool_use"}"#),
            (200, #"{"content": [{"type": "text", "text": "It's 19 degrees."}]}"#),
        ]
        let catalog = ModelCatalog().registering("claude", supportsImages: true) { AnthropicLanguageModel(apiKey: "k", model: "claude-haiku-5-5", session: URLSession(configuration: StubProtocol.configuration())) }
        let report = try await WorkflowRunner(catalog: catalog, requests: WeatherAPI())
            .run(weatherAgent("claude"), input: .text("Weather in Lisbon?"))
        #expect(report.output == .text("It's 19 degrees."))

        let messages = try #require(StubProtocol.sent.last?.json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" }?["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "tool_use")
        let reply = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(reply.first?["type"] as? String == "tool_result")
        #expect(reply.first?["tool_use_id"] as? String == "toolu_1")
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension NetworkTests {
    /// A plain grey picture, as PNG.
    private func photo(width: Int = 300, height: Int = 200) -> ImageValue {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return ImageValue(data: data as Data, contentType: "image/png")
    }

    private func reader(_ model: ModelID) -> Workflow {
        Workflow(name: "OCR", steps: [Step("read", .readImage(instruction: "Read the receipt."), model: model)])
    }

    @Test func claudeReadsImagesAsImageBlocks() async throws {
        StubProtocol.reply = (200, #"{"content": [{"type": "text", "text": "TOTAL 8.30"}]}"#)
        let catalog = ModelCatalog().registering("claude", supportsImages: true) { AnthropicLanguageModel(apiKey: "k", model: "claude-haiku-5-5", session: URLSession(configuration: StubProtocol.configuration())) }
        let report = try await WorkflowRunner(catalog: catalog).run(reader("claude"), input: .image(photo()))
        #expect(report.output == .text("TOTAL 8.30"))

        let messages = try #require(StubProtocol.sent.first?.json["messages"] as? [[String: Any]])
        let blocks = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["text", "image"])
        let source = try #require(blocks.last?["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        let data = try #require(Data(base64Encoded: source["data"] as? String ?? ""))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(blocks.first?["text"] as? String == "Read the receipt.")
    }

    @Test func openAICompatibleServersReadImagesAsDataURLs() async throws {
        StubProtocol.reply = (200, #"{"choices": [{"message": {"content": "TOTAL 8.30"}}]}"#)
        let catalog = ModelCatalog().registering("local", supportsImages: true) {
            OpenAILanguageModel(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "qwen2.5vl", session: URLSession(configuration: StubProtocol.configuration()))
        }
        let report = try await WorkflowRunner(catalog: catalog).run(reader("local"), input: .image(photo()))
        #expect(report.output == .text("TOTAL 8.30"))

        let messages = try #require(StubProtocol.sent.first?.json["messages"] as? [[String: Any]])
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
        let url = try #require((parts.last?["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url.hasPrefix("data:image/png;base64,"))
    }

    @Test func textPromptsStayPlainText() async throws {
        StubProtocol.reply = (200, #"{"choices": [{"message": {"content": "Hi"}}]}"#)
        let catalog = ModelCatalog().registering("local", supportsImages: true) {
            OpenAILanguageModel(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "llama3.2", session: URLSession(configuration: StubProtocol.configuration()))
        }
        let ask = Workflow(name: "Ask", steps: [Step("hi", .prompt(instruction: "Say hi."), model: "local")])
        _ = try await WorkflowRunner(catalog: catalog).run(ask, input: .text(""))
        let messages = try #require(StubProtocol.sent.first?.json["messages"] as? [[String: Any]])
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
    }
}
