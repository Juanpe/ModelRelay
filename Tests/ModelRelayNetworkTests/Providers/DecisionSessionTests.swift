import Foundation
import ModelRelay
import ModelRelayCloud
import Testing

struct DecisionSessionTests {
    @Test func concurrentModelsKeepTheirOwnTransport() async throws {
        let positiveSession: URLSession = session(using: DecisionReplyProtocol.self)
        let negativeSession: URLSession = session(using: NegativeDecisionReplyProtocol.self)
        defer {
            positiveSession.invalidateAndCancel()
            negativeSession.invalidateAndCancel()
        }
        let positive: DecisionsAPIModel = .init(apiKey: "test-only", session: positiveSession)
        let negative: DecisionsAPIModel = .init(apiKey: "test-only", session: negativeSession)
        let questions: [Question] = [.init("urgent", "Is it urgent?", .yesNo)]

        async let first: [Answer] = positive.decide(questions, about: "Same input")
        async let second: [Answer] = negative.decide(questions, about: "Same input")
        let (yes, no): ([Answer], [Answer]) = try await (first, second)

        #expect(yes.first?.result == .yesNo(true))
        #expect(no.first?.result == .yesNo(false))
        #expect(try await positive.decide(questions, about: "Again").first?.result == .yesNo(true))
        #expect(try await negative.decide(questions, about: "Again").first?.result == .yesNo(false))
    }

    @Test func equalityIncludesTheSessionIdentity() {
        let firstSession: URLSession = session(using: DecisionReplyProtocol.self)
        let secondSession: URLSession = session(using: DecisionReplyProtocol.self)
        defer {
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        let first: DecisionsAPIModel = .init(apiKey: "test-only", session: firstSession)
        let sameTransport: DecisionsAPIModel = .init(apiKey: "test-only", session: firstSession)
        let otherTransport: DecisionsAPIModel = .init(apiKey: "test-only", session: secondSession)

        #expect(first == sameTransport)
        #expect(first != otherTransport)
        #expect(Set([first, sameTransport, otherTransport]).count == 2)
        #expect(!first.description.contains("test-only"))
    }

    private func session(using protocolType: URLProtocol.Type) -> URLSession {
        let configuration: URLSessionConfiguration = .ephemeral
        configuration.protocolClasses = [protocolType]
        return .init(configuration: configuration)
    }
}

private class DecisionReplyProtocol: URLProtocol, @unchecked Sendable {
    private let successStatus: Int = 200
    var probability: Double { 1 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: successStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: [String: Any] = ["answers": [["type": "predicate", "name": "urgent", "probability": probability]]]

        do {
            let data: Data = try JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class NegativeDecisionReplyProtocol: DecisionReplyProtocol, @unchecked Sendable {
    override var probability: Double { 0 }
}
