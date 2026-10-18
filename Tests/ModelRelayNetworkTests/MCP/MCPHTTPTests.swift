import Foundation
import ModelRelay
import Testing
@testable import ModelRelayMCP

extension NetworkTests {
    private func signInPlan() throws -> MCPSignIn.Plan {
        MCPSignIn.Plan(
            resource: "https://mcp.test/mcp",
            authorizationEndpoint: try #require(URL(string: "https://auth.test/authorize")),
            tokenEndpoint: try #require(URL(string: "https://auth.test/token")),
            registrationEndpoint: URL(string: "https://auth.test/register")
        )
    }

    @Test(arguments: [400, 403, 429, 500])
    func mcpHTTPFailuresKeepStatusAndMessage(_ status: Int) async throws {
        StubProtocol.reply = (status, #"{"error":{"message":"MCP reason"}}"#)
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client: MCPClient = .init(url: try #require(URL(string: "https://mcp.test")), headers: [:], clientName: "Tests", session: session)

        await #expect(throws: MCPError.http(status: status, message: "MCP reason")) {
            try await client.start()
        }

        #expect(StubProtocol.sent.count == 1)
    }

    @Test func mcpHTTPUnauthorizedKeepsChallengeEvenWithAnInvalidBody() async throws {
        StubProtocol.reply = (401, "not JSON")
        StubProtocol.headerQueue = [["wWw-AuThEnTiCaTe": "Bearer challenge"]]
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client: MCPClient = .init(url: try #require(URL(string: "https://mcp.test")), headers: [:], clientName: "Tests", session: session)

        await #expect(throws: MCPError.needsSignIn(challenge: "Bearer challenge")) {
            try await client.start()
        }
    }

    @Test func mcpRejectsNonHTTPResponses() async throws {
        StubProtocol.responseIsHTTP = false
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client: MCPClient = .init(url: try #require(URL(string: "https://mcp.test")), headers: [:], clientName: "Tests", session: session)

        await #expect(throws: MCPError.invalidResponse("not HTTP")) {
            try await client.start()
        }
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_grant","error_description":"Expired code"}"#, "Expired code"),
        (401, #"{"error":"invalid_client"}"#, "invalid_client"),
        (500, "not JSON", "HTTP 500"),
        (400, #"{"access_token":"not-valid-on-failure"}"#, "HTTP 400"),
        (200, "not JSON", "invalid JSON response"),
        (200, "[]", "invalid JSON response"),
        (200, "{}", "no access token"),
        (200, #"{"access_token":""}"#, "no access token"),
        (200, #"{"access_token":42}"#, "no access token"),
        (200, #"{"error":"invalid_grant","error_description":"Expired code"}"#, "Expired code"),
        (200, #"{"error":"invalid_grant"}"#, "invalid_grant"),
    ])
    func oauthDistinguishesHTTPAndTokenFailures(_ status: Int, _ body: String, _ reason: String) async throws {
        StubProtocol.reply = (status, body)
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let plan: MCPSignIn.Plan = try signInPlan()

        await #expect(throws: MCPSignIn.Failure.tokenRefused(reason)) {
            try await MCPSignIn.refresh(
                MCPSignIn.Tokens(access: "old", refresh: "refresh"),
                plan: plan,
                client: MCPSignIn.Client(id: "client"),
                session: session
            )
        }

        #expect(StubProtocol.sent.count == 1)
    }

    @Test func oauthRejectsNonHTTPResponses() async throws {
        StubProtocol.responseIsHTTP = false
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let plan: MCPSignIn.Plan = try signInPlan()

        await #expect(throws: MCPSignIn.Failure.tokenRefused("not an HTTP response")) {
            try await MCPSignIn.refresh(
                MCPSignIn.Tokens(access: "old", refresh: "refresh"),
                plan: plan,
                client: MCPSignIn.Client(id: "client"),
                session: session
            )
        }
    }

    @Test(arguments: [
        (400, #"{"client_id":"not-valid-on-failure"}"#),
        (200, "not JSON"),
        (200, "[]"),
        (200, "{}"),
        (200, #"{"client_id":""}"#),
    ])
    func oauthRegistrationRejectsInvalidResponses(_ status: Int, _ body: String) async throws {
        StubProtocol.reply = (status, body)
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let plan: MCPSignIn.Plan = try signInPlan()

        await #expect(throws: MCPSignIn.Failure.cantRegister) {
            try await MCPSignIn.register(plan, redirectURI: "app://callback", clientName: "Tests", session: session)
        }
    }

    @Test func oauthDiscoveryIgnoresMetadataFromFailedHTTPResponses() async throws {
        StubProtocol.reply = (404, #"{"authorization_endpoint":"https://ignored.test/authorize","token_endpoint":"https://ignored.test/token"}"#)
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }

        let plan: MCPSignIn.Plan = try await MCPSignIn.discover(server: #require(URL(string: "https://mcp.test/mcp")), session: session)

        #expect(plan.authorizationEndpoint.absoluteString == "https://mcp.test/authorize")
        #expect(plan.tokenEndpoint.absoluteString == "https://mcp.test/token")
    }

    @Test func oauthMetadataRejectsNonHTTPResponses() async throws {
        StubProtocol.responseIsHTTP = false
        let session: URLSession = .init(configuration: StubProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let plan: MCPSignIn.Plan = try signInPlan()

        await #expect(throws: MCPSignIn.Failure.cantRegister) {
            try await MCPSignIn.register(plan, redirectURI: "app://callback", clientName: "Tests", session: session)
        }

        let discovered: MCPSignIn.Plan = try await MCPSignIn.discover(server: #require(URL(string: "https://mcp.test/mcp")), session: session)

        #expect(discovered.authorizationEndpoint.absoluteString == "https://mcp.test/authorize")
        #expect(discovered.tokenEndpoint.absoluteString == "https://mcp.test/token")
    }
}
