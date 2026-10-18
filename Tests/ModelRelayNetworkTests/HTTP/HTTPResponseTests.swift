import Foundation
import ModelRelay
import ModelRelayHTTP
import Testing

struct URLSessionHTTPResponseTests {
    @Test func adaptsStatusHeadersAndBodyWithoutValidatingEndpointPolicy() throws {
        let url: URL = try #require(URL(string: "https://api.test"))
        let response: HTTPURLResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["WWW-Authenticate": "Bearer challenge", "Mcp-Session-Id": "session-1"]
        ))
        let body: Data = .init(#"{"error":"unauthorized"}"#.utf8)

        let reply: HTTPResponse = try #require(HTTPResponse(data: body, response: response))

        #expect(reply.status == 401)
        #expect(reply.body == body)
        #expect(reply.header(named: "www-authenticate") == "Bearer challenge")
        #expect(reply.header(named: "MCP-SESSION-ID") == "session-1")
    }

    @Test func rejectsNonHTTPResponsesInsteadOfInventingStatusZero() throws {
        let url: URL = try #require(URL(string: "https://api.test"))
        let response: URLResponse = .init(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)

        #expect(HTTPResponse(data: Data(), response: response) == nil)
    }
}
