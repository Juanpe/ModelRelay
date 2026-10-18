import Foundation
import ModelRelayHTTP
import Testing
@testable import ModelRelay
@testable import ModelRelayCloud

extension NetworkTests {
    @Test(arguments: [200, 204, 299, 400, 500])
    func requestPerformerLeavesStatusPolicyToTheWorkflow(_ status: Int) async throws {
        StubProtocol.reply = (status, "")
        let request: PreparedRequest = try RequestBuilder.prepare(HTTPRequest(url: "https://api.test"), secrets: [:]) { _ in nil }

        let reply: HTTPResponse = try await URLSessionRequestPerformer(configuration: StubProtocol.configuration()).perform(request)

        #expect(reply.status == status)
        #expect(StubProtocol.sent.count == 1)
    }

    @Test func requestPerformerRejectsNonHTTPResponses() async throws {
        StubProtocol.responseIsHTTP = false
        let request: PreparedRequest = try RequestBuilder.prepare(HTTPRequest(url: "https://api.test"), secrets: [:]) { _ in nil }

        await #expect(throws: URLError(.badServerResponse)) {
            try await URLSessionRequestPerformer(configuration: StubProtocol.configuration()).perform(request)
        }
    }

    @Test(arguments: [400, 401, 403, 429, 500])
    func cloudHTTPPreservesStatusAndServerMessage(_ status: Int) async throws {
        StubProtocol.reply = (status, #"{"error":{"message":"Provider reason"}}"#)
        let url: URL = try #require(URL(string: "https://decisions.test"))

        do {
            _ = try await CloudHTTP(session: session).postJSON(url, headers: [:], body: [:])
            Issue.record("Expected the HTTP error")
        } catch let error as CloudModelError {
            #expect(error.status == status)
            #expect(error.message == "Provider reason")
        }

        #expect(StubProtocol.sent.count == 1)
    }

    @Test(arguments: ["", "not JSON", "[]"])
    func cloudHTTPRejectsInvalidSuccessfulJSON(_ body: String) async throws {
        StubProtocol.reply = (200, body)
        let url: URL = try #require(URL(string: "https://decisions.test"))

        do {
            _ = try await CloudHTTP(session: session).postJSON(url, headers: [:], body: [:])
            Issue.record("Expected invalid JSON")
        } catch let error as CloudModelError {
            #expect(error.status == 200)
            #expect(error.message == "The server returned an invalid JSON object")
        }
    }

    @Test func cloudHTTPRejectsNonHTTPResponses() async throws {
        StubProtocol.responseIsHTTP = false
        let url: URL = try #require(URL(string: "https://decisions.test"))

        do {
            _ = try await CloudHTTP(session: session).postJSON(url, headers: [:], body: [:])
            Issue.record("Expected a non-HTTP response error")
        } catch let error as CloudModelError {
            #expect(error.status == 0)
            #expect(error.workflowFailureCategory == .transport)
        }
    }
}
