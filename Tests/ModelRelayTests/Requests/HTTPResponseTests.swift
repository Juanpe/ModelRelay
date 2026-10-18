import Foundation
import Testing
@testable import ModelRelay

struct HTTPResponseTests {
    private enum Failure: Error, Equatable {
        case rejected(Int)
    }

    @Test(arguments: [200, 201, 202, 204, 206, 299])
    func acceptsEverySuccessfulStatus(_ status: Int) throws {
        let response: HTTPResponse = .init(status: status, body: Data())
        var evaluatedFailure: Bool = false

        func failure() -> Failure {
            evaluatedFailure = true
            return .rejected(status)
        }

        try response.validateSuccess(or: failure())

        #expect(!evaluatedFailure)
    }

    @Test(arguments: [0, 199, 300, 302, 400, 401, 429, 500])
    func rejectsOtherStatusesWithTheCallersError(_ status: Int) {
        let response: HTTPResponse = .init(status: status, body: Data())

        #expect(throws: Failure.rejected(status)) {
            try response.validateSuccess(or: Failure.rejected(status))
        }
    }

    @Test func headersAreCaseInsensitiveAndPreserveTheirValues() {
        let response: HTTPResponse = .init(status: 401, body: Data(), headers: ["WWW-Authenticate": "Bearer PRIVATE_CHALLENGE"])

        #expect(response.header(named: "www-authenticate") == "Bearer PRIVATE_CHALLENGE")
        #expect(response.header(named: "WWW-AUTHENTICATE") == "Bearer PRIVATE_CHALLENGE")
        #expect(response.header(named: "missing") == nil)
        #expect(HTTPResponse(status: 200, body: Data()).header(named: "Content-Type") == nil)
    }

    @Test func readsJSONObjectWithoutTurningOtherBodiesIntoEmptyObjects() {
        let response: HTTPResponse = .init(status: 200, body: Data(#"{"access_token":"token"}"#.utf8))

        #expect(response.jsonObject?["access_token"] as? String == "token")
        #expect(HTTPResponse.jsonObject(from: response.body)?["access_token"] as? String == "token")
    }

    @Test(arguments: ["", "not JSON", "[]", "null", "true", "42", #""text""#])
    func nonObjectsAreNotJSONObjectResponses(_ body: String) {
        let response: HTTPResponse = .init(status: 200, body: Data(body.utf8))

        #expect(response.jsonObject == nil)
    }

    @Test func eachProtocolChoosesItsErrorMessagePriority() {
        let object: [String: Any] = [
            "description": "Request reason",
            "error_description": "OAuth reason",
            "error": ["message": "MCP reason"],
            "message": "Generic reason",
        ]

        #expect(HTTPResponse.errorMessage(in: object) == "Request reason")
        #expect(HTTPResponse.errorMessage(in: object, keys: ["error_description", "error"]) == "OAuth reason")
        #expect(HTTPResponse.errorMessage(in: object, keys: ["error", "error_description", "message"]) == "MCP reason")
        #expect(HTTPResponse.errorMessage(in: ["error": "invalid_grant"]) == "invalid_grant")
        #expect(HTTPResponse.errorMessage(in: ["error": 42]) == nil)
        #expect(HTTPResponse.errorMessage(in: [:]) == nil)
    }
}
