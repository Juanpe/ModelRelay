import Foundation
import Synchronization
import Testing
@testable import ModelRelay

/// Collects the records the executor reports while it runs.
private final class Observed: Sendable {
    private let records = Mutex<[StepRecord]>([])
    var all: [StepRecord] { records.withLock { $0 } }
    func add(_ record: StepRecord) { records.withLock { $0.append(record) } }
}

@Suite struct StepTraceTests {
    @Test func modelStepsRecordThePromptTheyWereGiven() async throws {
        let model = ScriptedModel("small", replies: ["Short."])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Sum", steps: [
            Step("summary", .prompt(instruction: "Summarize this."), model: "small"),
        ])
        let report = try await executor.run(workflow, input: .text("A long article."))
        let input = try #require(report.records.first?.input)
        #expect(input.contains("Summarize this."))
        #expect(input.contains("A long article."))
        #expect(report.records.first?.failure == nil)
    }

    @Test func theFailedStepIsReportedWithItsInputAndReason() async throws {
        let model = ScriptedModel("small", replies: [nil])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Fails", steps: [
            Step("greet", .template("Hello {{input}}")),
            Step("summary", .prompt(instruction: "Summarize: {{greet}}"), model: "small"),
        ])
        let observed = Observed()
        await #expect(throws: RelayError.self) {
            try await executor.execute(workflow, input: .text("Ana")).observing(onStep: observed.add)
        }
        let failed = try #require(observed.all.last)
        #expect(failed.step == "summary")
        #expect(failed.input == "Summarize: Hello Ana")
        #expect(failed.failure?.isEmpty == false)
        #expect(observed.all.first?.failure == nil)
    }

    @Test func requestsRecordWhatWasSentWithSecretsHidden() async throws {
        let server = FakeServer(json: #"{"ok": true}"#)
        let executor = WorkflowExecutor(requests: server, secrets: FakeSecrets(values: ["TOKEN": "s3cr3t"]))
        let workflow = Workflow(name: "Call", steps: [
            Step("call", .request(HTTPRequest(url: "https://api.example.com/bot{{secret.TOKEN}}/send?text={{input}}"))),
        ])
        let report = try await executor.run(workflow, input: .text("hi"))
        let input = try #require(report.records.first?.input)
        #expect(input.hasPrefix("GET https://api.example.com/bot"))
        #expect(input.contains("text=hi"))
        #expect(!input.contains("s3cr3t"))
    }

    @Test func errorResponsesSayWhyWithoutShowingSecrets() async throws {
        let server = FakeServer(status: 400, json: #"{"ok": false, "description": "Bad Request: chat not found for s3cr3t"}"#)
        let executor = WorkflowExecutor(requests: server, secrets: FakeSecrets(values: ["TOKEN": "s3cr3t"]))
        let workflow = Workflow(name: "Call", steps: [
            Step("call", .request(HTTPRequest(url: "https://api.example.com/bot{{secret.TOKEN}}/send"))),
        ])
        let observed = Observed()
        await #expect(throws: expectedOperationFailure(step: "call", reason: "The server answered HTTP 400: Bad Request: chat not found for •••", category: .requestRejected)) {
            try await executor.execute(workflow, input: .text("")).observing(onStep: observed.add)
        }
        let failed = try #require(observed.all.last)
        #expect(failed.failure == "The server answered HTTP 400: Bad Request: chat not found for •••")
        #expect(failed.input?.contains("s3cr3t") == false)
    }

    @Test func errorDetailReadsCommonShapes() {
        #expect(RequestBuilder.errorDetail(Data(#"{"error": {"message": "Invalid key"}}"#.utf8)) == "Invalid key")
        #expect(RequestBuilder.errorDetail(Data(#"{"message": "Not found"}"#.utf8)) == "Not found")
        #expect(RequestBuilder.errorDetail(Data("<html><body>502</body></html>".utf8)) == nil)
        #expect(RequestBuilder.errorDetail(Data("plain reason".utf8)) == "plain reason")
        #expect(RequestBuilder.errorDetail(Data("{}".utf8)) == nil)
    }

    @Test func appErrorsReadAsTheirOwnMessage() {
        struct Locked: LocalizedError { var errorDescription: String? { "The Keychain is locked." } }
        #expect(failureReason(Locked()) == "The Keychain is locked.")
    }
}
