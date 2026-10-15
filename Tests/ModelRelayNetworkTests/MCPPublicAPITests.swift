import Foundation
import ModelRelayMCP
import Testing

// Import the module normally: a consuming package must be able to supply
// endpoints and credentials without @testable, a UI, or a particular store.
@Suite struct MCPPublicAPITests {
    @Test func hostCanSupplyEndpointsAndAPreregisteredClient() throws {
        let plan = MCPSignIn.Plan(
            resource: "https://mcp.example.com/mcp",
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            scopes: ["read"]
        )
        let client = MCPSignIn.Client(id: "example-client")
        let restored = try JSONDecoder().decode(MCPSignIn.Plan.self, from: JSONEncoder().encode(plan))
        #expect(restored == plan)
        #expect(plan.registrationEndpoint == nil)
        #expect(client.secret == nil)

        let first = MCPSignIn.start(plan, client: client, redirectURI: "example-client://oauth/callback")
        let second = MCPSignIn.start(plan, client: client, redirectURI: "example-client://oauth/callback")
        let items = URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "client_id" }?.value == client.id)
        #expect(items.first { $0.name == "scope" }?.value == "read")
        #expect(items.first { $0.name == "resource" }?.value == plan.resource)
        #expect(first.url != second.url)
    }

    @Test func hostCanRestoreTokensWithoutAdoptingAStore() throws {
        let tokens = MCPSignIn.Tokens(access: "test-access", refresh: "test-refresh",
                                      expiresAt: Date().addingTimeInterval(3_600))
        let restored = try JSONDecoder().decode(MCPSignIn.Tokens.self, from: JSONEncoder().encode(tokens))
        #expect(restored == tokens)
        #expect(!restored.isExpired)
        #expect(MCPSignIn.Tokens(access: "test-access", expiresAt: Date().addingTimeInterval(30)).isExpired)
        #expect(MCPSignIn.Tokens(access: "test-access", expiresAt: .distantPast).isExpired)
        #expect(!MCPSignIn.Tokens(access: "test-access").isExpired)
    }
}
