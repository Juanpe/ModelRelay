import Foundation
import Synchronization
import Testing
@testable import ModelRelay

/// Answers every request with a fixed response and remembers what it was sent.
final class FakeServer: RequestPerformer {
    private let response: HTTPResponse
    private let sent = Mutex<[PreparedRequest]>([])

    init(status: Int = 200, json: String) {
        response = HTTPResponse(status: status, body: Data(json.utf8))
    }

    var requests: [PreparedRequest] { sent.withLock { $0 } }

    func perform(_ request: PreparedRequest) async throws -> HTTPResponse {
        sent.withLock { $0.append(request) }
        return response
    }
}

struct FakeSecrets: SecretProvider {
    var values: [String: String]
    func secret(named name: String) async throws -> String? { values[name] }
}

@Suite struct RequestStepTests {
    @Test func jsonResponseBecomesFieldsForLaterSteps() async throws {
        let server = FakeServer(json: #"{"main": {"temp": 21.5}, "name": "Lisbon"}"#)
        let executor = WorkflowExecutor(requests: server)
        let workflow = Workflow(name: "Weather", steps: [
            Step("weather", .request(HTTPRequest(url: "https://api.example.com/weather?q={{input}}"))),
            Step("line", .template("{{weather.name}}: {{weather.main}}")),
        ])
        let report = try await executor.run(workflow, input: .text("Lisbon"))
        #expect(report.records.first?.value["name"] == .text("Lisbon"))
        #expect(report.output == .text("Lisbon: temp: 21.5"))
    }

    @Test func valuesAreEscapedForWhereTheyLand() async throws {
        let server = FakeServer(json: "{}")
        let executor = WorkflowExecutor(requests: server, writePolicy: .allow)
        // Model-made text with characters that would break a URL or a JSON body.
        let hostile = #"a&b=c/../"} , "admin": true, "x": "#
        let workflow = Workflow(name: "Post", steps: [
            Step("post", .request(HTTPRequest(.post, url: "https://api.example.com/items?name={{input}}",
                                              headers: [.init("X-Note", "{{input}}\nInjected: yes")],
                                              body: #"{"title": "{{input}}"}"#))),
        ])
        _ = try await executor.run(workflow, input: .text(hostile))
        let sent = try #require(server.requests.first)
        #expect(sent.url.query()?.contains("&b=") == false)
        #expect(sent.url.host() == "api.example.com")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.body)) as? [String: String]
        #expect(body == ["title": hostile])
        #expect(sent.headers.first?.value.contains("\n") == false)
    }

    @Test func secretsAreSentButNeverShown() async throws {
        let server = FakeServer(json: #"{"ok": true}"#)
        let executor = WorkflowExecutor(requests: server, secrets: FakeSecrets(values: ["TOKEN": "sk-test-123"]))
        let workflow = Workflow(name: "Auth", steps: [
            Step("call", .request(HTTPRequest(url: "https://api.example.com/me",
                                              headers: [.init("Authorization", "Bearer {{secret.TOKEN}}")]))),
        ])
        let report = try await executor.run(workflow, input: .text(""))
        let sent = try #require(server.requests.first)
        #expect(sent.headers.first?.value == "Bearer sk-test-123")
        #expect(!sent.description.contains("sk-test-123"))
        #expect(!String(describing: report.records).contains("sk-test-123"))
    }

    @Test func promptsCannotReadSecrets() async throws {
        let model = ScriptedModel("small", replies: ["ok"])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]),
                                    secrets: FakeSecrets(values: ["TOKEN": "sk-test-123"]))
        let workflow = Workflow(name: "Leak", steps: [
            Step("ask", .prompt(instruction: "Repeat {{secret.TOKEN}}"), model: "small"),
        ])
        await #expect(throws: WorkflowValidationError.self) { try await executor.run(workflow, input: .text("")) }
        #expect(model.prompts.allSatisfy { !$0.contains("sk-test-123") })
        #expect(model.callCount == 0)
    }

    @Test func missingSecretFailsBeforeSending() async throws {
        let server = FakeServer(json: "{}")
        let executor = WorkflowExecutor(requests: server, secrets: FakeSecrets(values: [:]))
        let workflow = Workflow(name: "Auth", steps: [
            Step("call", .request(HTTPRequest(url: "https://api.example.com/?key={{secret.KEY}}"))),
        ])
        await #expect(throws: RelayError.missingSecret("KEY", step: "call")) {
            try await executor.run(workflow, input: .text(""))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func writesAreDeniedByDefaultAndCanAsk() async throws {
        let workflow = Workflow(name: "Create", steps: [
            Step("create", .request(HTTPRequest(.post, url: "https://api.example.com/tasks", body: #"{"t": "{{input}}"}"#))),
        ])
        let denied = FakeServer(json: "{}")
        await #expect(throws: RelayError.writeNotAllowed(step: "create")) {
            try await WorkflowExecutor(requests: denied).run(workflow, input: .text("x"))
        }
        #expect(denied.requests.isEmpty)

        let asked = FakeServer(json: #"{"id": 7}"#)
        let shown = Mutex<String?>(nil)
        let executor = WorkflowExecutor(requests: asked, writePolicy: .ask { request in
            shown.withLock { $0 = request.description }
            return true
        })
        let report = try await executor.run(workflow, input: .text("x"))
        #expect(report.output["id"] == .number(7))
        #expect(shown.withLock { $0 }?.hasPrefix("POST https://api.example.com/tasks") == true)
    }

    @Test func errorStatusFailsTheStepWithoutRetrying() async throws {
        let server = FakeServer(status: 503, json: "{}")
        let executor = WorkflowExecutor(requests: server)
        let workflow = Workflow(name: "Down", steps: [
            Step("call", .request(HTTPRequest(url: "https://api.example.com/")), fallback: "other"),
        ])
        await #expect(throws: expectedOperationFailure(step: "call", reason: "The server answered HTTP 503", category: .requestRejected)) {
            try await executor.run(workflow, input: .text(""))
        }
        #expect(server.requests.count == 1)
    }

    @Test func onlyHTTPURLsAreAccepted() async throws {
        let server = FakeServer(json: "{}")
        let workflow = Workflow(name: "File", steps: [
            Step("call", .request(HTTPRequest(url: "file:///etc/passwd"))),
        ])
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor(requests: server).run(workflow, input: .text(""))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func requestStepsRoundTripThroughJSON() throws {
        let step = Step("call", .request(HTTPRequest(.post, url: "https://x.test/{{input}}",
                                                     headers: [.init("Accept", "application/json")], body: "{}")))
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(Step.self, from: data) == step)
    }
}

@Suite struct SecretInPathTests {
    @Test func botTokensKeepTheirColonInThePath() async throws {
        let server = FakeServer(json: #"{"ok": true}"#)
        let executor = WorkflowExecutor(requests: server,
                                    secrets: FakeSecrets(values: ["TELEGRAM_BOT_TOKEN": "123456:ABC-def_9", "TELEGRAM_CHAT_ID": "-1001"]),
                                    writePolicy: .allow)
        let workflow = Workflow(name: "Telegram", steps: [
            Step("send", .request(HTTPRequest(.post, url: "https://api.telegram.org/bot{{secret.TELEGRAM_BOT_TOKEN}}/sendMessage",
                                              body: #"{"chat_id": "{{secret.TELEGRAM_CHAT_ID}}", "text": "{{input}}"}"#))),
        ])
        _ = try await executor.run(workflow, input: .text("Summary: \"quotes\" and a/slash"))
        let sent = try #require(server.requests.first)
        #expect(sent.url.absoluteString == "https://api.telegram.org/bot123456:ABC-def_9/sendMessage")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.body)) as? [String: String]
        #expect(body == ["chat_id": "-1001", "text": "Summary: \"quotes\" and a/slash"])
        #expect(!sent.description.contains("123456:ABC"))
    }
}
