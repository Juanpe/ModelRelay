import Foundation
import ModelRelay
import Synchronization
import Testing
@testable import ModelRelayMCP

private struct Keys: SecretProvider {
    var values: [String: String]
    func secret(named name: String) async throws -> String? { values[name] }
}

// In the serialized network suite: StubProtocol's replies are shared.
extension NetworkTests {
    private var linear: ToolKit {
        ToolKit(
            id: "linear",
            name: "Linear",
            tools: [],
            server: ToolServer(url: "https://mcp.example.com/mcp", headers: [.init("Authorization", "Bearer {{secret.LINEAR_KEY}}")])
        )
    }

    private func queueSession(tools: String, call: String) {
        StubProtocol.queue = [
            (200, #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"t","version":"1"}}}"#),
            (202, ""),
            (200, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":\(tools)}}\n\n"),
            (200, call),
        ]
        StubProtocol.headerQueue = [
            ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"],
            [:],
            ["Content-Type": "text/event-stream"],
            ["Content-Type": "application/json"],
        ]
    }

    private var connector: MCPConnector {
        MCPConnector(
            secrets: Keys(values: ["LINEAR_KEY": "lin_secret"]),
            clientName: "ExampleClient",
            configuration: StubProtocol.configuration()
        )
    }

    @Test func mcpServersListAndCallToolsInOneSession() async throws {
        queueSession(
            tools: #"[{"name":"create_issue","description":"Creates an issue.","inputSchema":{"type":"object","properties":{"title":{"type":"string"},"priority":{"type":"integer"}},"required":["title"]}}]"#,
            call: #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"id\":\"ISS-1\"}"}]}}"#
        )
        let workflow = Workflow(name: "File", steps: [
            Step("file", .useTool(kit: "linear", tool: "create_issue", arguments: ["title": "{{input}}", "priority": "2"])),
        ])
        let executor = WorkflowExecutor(writePolicy: .allow, toolKits: [linear], toolServers: connector)
        let report = try await executor.run(workflow, input: .text("Login broken"))
        #expect(report.output["id"] == .text("ISS-1"))

        let sent = StubProtocol.sent
        #expect(sent.map { $0.json["method"] as? String } == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(sent[0].headers["Accept"] == "application/json, text/event-stream")
        #expect(sent[0].headers["Authorization"] == "Bearer lin_secret")
        #expect(sent[2].headers["Mcp-Session-Id"] == "session-1")
        #expect(sent[2].headers["MCP-Protocol-Version"] == "2025-06-18")
        let params = try #require(sent[3].json["params"] as? [String: Any])
        #expect(params["name"] as? String == "create_issue")
        let arguments = try #require(params["arguments"] as? [String: Any])
        #expect(arguments["title"] as? String == "Login broken")
        #expect(arguments["priority"] as? Double == 2)
        // The step's record names the call but never the key.
        #expect(report.records.first?.input?.contains("create_issue") == true)
        #expect(report.records.first?.input?.contains("lin_secret") == false)
    }

    @Test func mcpToolFailuresAndSignInSayWhy() async throws {
        queueSession(
            tools: #"[{"name":"create_issue","inputSchema":{"type":"object","properties":{}}}]"#,
            call: #"{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"Team not found"}]}}"#
        )
        let workflow = Workflow(name: "File", steps: [Step("file", .useTool(kit: "linear", tool: "create_issue", arguments: [:]))])
        do {
            _ = try await WorkflowExecutor(writePolicy: .allow, toolKits: [linear], toolServers: connector).run(workflow, input: .text(""))
            Issue.record("expected a tool failure")
        } catch let RelayError.operationFailed(step, failure) {
            #expect(step == "file")
            #expect(failure.info.message == "Team not found")
            #expect(failure.info.outcomeUncertain)
            #expect(failure.rootCause as? MCPError == .toolFailed("Team not found"))
        }

        StubProtocol.sent = []
        StubProtocol.queue = [(401, "")]
        StubProtocol.headerQueue = [["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#]]
        do {
            _ = try await connector.connect(to: linear)
            Issue.record("Expected a sign-in error")
        } catch let MCPError.needsSignIn(challenge) {
            #expect(challenge?.contains("resource_metadata") == true)
        }
    }

    @Test func executorPreservesTypedMCPSignInAndEmitsOnlyTheCategory() async throws {
        StubProtocol.sent = []
        StubProtocol.queue = [(401, "")]
        StubProtocol.headerQueue = [["WWW-Authenticate": "Bearer PRIVATE_CHALLENGE"]]
        let workflow = Workflow("Authentication") { Step.useTool("lookup", kit: "linear", tool: "lookup") }
        let events = Mutex<[WorkflowExecutionEvent]>([])
        do {
            let execution = WorkflowExecutor(toolKits: [linear], toolServers: connector).stream(workflow, input: .null)
            for try await update in execution {
                if case let .event(event) = update { events.withLock { $0.append(event) } }
            }
            _ = try await execution.result
            Issue.record("expected sign in")
        } catch let RelayError.operationFailed(_, failure) {
            #expect(failure.info.category == .authenticationRequired)
            guard case let .needsSignIn(challenge) = failure.rootCause as? MCPError else { Issue.record("lost MCP cause"); return }
            #expect(challenge == "Bearer PRIVATE_CHALLENGE")
            let json = String(decoding: try JSONEncoder().encode(events.withLock { $0 }), as: UTF8.self)
            #expect(!json.contains("PRIVATE_CHALLENGE"))
        }
    }

    @Test func mcpSchemasBecomeFieldsAndHintsDecidePermission() throws {
        let tool = try #require(MCPSchema.tool(from: [
            "name": "search",
            "description": "Finds things.",
            "annotations": ["readOnlyHint": true],
            "inputSchema": [
                "type": "object",
                "required": ["query"],
                "properties": [
                    "query": ["type": "string", "description": "What to find"],
                    "limit": ["type": "integer"],
                    "state": ["type": "string", "enum": ["open", "closed"]],
                    "archived": ["type": ["boolean", "null"]],
                    "labels": ["type": "array", "items": ["type": "string"]],
                    "filter": ["type": "object", "description": "A filter."],
                ],
            ],
        ]))
        #expect(tool.parameters.map(\.name) == ["query", "archived", "filter", "labels", "limit", "state"])
        #expect(tool.parameters.map(\.kind) == [.text, .bool, .text, .list(.text), .number, .choice(["open", "closed"])])
        #expect(tool.parameters.first { $0.name == "filter" }?.description == "A filter. Write it as JSON.")
        #expect(tool.required == ["query"])
        #expect(!tool.changesSomething)
        #expect(MCPSchema.tool(from: ["name": "delete_all"])?.changesSomething == true)
    }

    @Test func mcpSignInFindsTheServerRegistersAndTradesTheCode() async throws {
        let session = URLSession(configuration: StubProtocol.configuration())
        StubProtocol.queue = [
            (200, #"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["read","write"]}"#),
            (200, #"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register"}"#),
            (201, #"{"client_id":"example-client-123"}"#),
            (200, #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}"#),
            (200, #"{"access_token":"at-2","expires_in":3600}"#),
        ]
        let challenge = #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp""#
        let plan = try await MCPSignIn.discover(server: URL(string: "https://mcp.example.com/mcp")!, challenge: challenge, session: session)
        #expect(plan.authorizationEndpoint.absoluteString == "https://auth.example.com/authorize")
        #expect(plan.scopes == ["read", "write"])
        #expect(StubProtocol.sent[1].url.absoluteString == "https://auth.example.com/.well-known/oauth-authorization-server")

        let redirect = "example-client://oauth/callback"
        let client = try await MCPSignIn.register(plan, redirectURI: redirect, clientName: "ExampleClient", session: session)
        #expect(client.id == "example-client-123")
        #expect(StubProtocol.sent[2].json["token_endpoint_auth_method"] as? String == "none")
        #expect(StubProtocol.sent[2].json["redirect_uris"] as? [String] == [redirect])

        let attempt = MCPSignIn.start(plan, client: client, redirectURI: redirect)
        let query = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(item("code_challenge") == MCPSignIn.challenge(for: attempt.verifier))
        #expect(item("code_challenge_method") == "S256")
        #expect(item("resource") == "https://mcp.example.com/mcp")
        #expect(item("scope") == "read write")

        await #expect(throws: MCPSignIn.Failure.cancelledOrWrongState) {
            try await MCPSignIn.finish(
                attempt,
                callback: URL(string: "\(redirect)?code=abc&state=forged")!,
                plan: plan,
                client: client,
                redirectURI: redirect,
                session: session
            )
        }
        let tokens = try await MCPSignIn.finish(
            attempt,
            callback: URL(string: "\(redirect)?code=abc&state=\(attempt.state)")!,
            plan: plan,
            client: client,
            redirectURI: redirect,
            session: session
        )
        #expect(tokens.access == "at-1")
        #expect(!tokens.isExpired)
        let form = Dictionary(uniqueKeysWithValues: String(decoding: StubProtocol.sent[3].body, as: UTF8.self)
            .split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            })
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "abc")
        #expect(form["code_verifier"] == attempt.verifier)
        #expect(form["client_id"] == "example-client-123")
        #expect(form["resource"] == "https://mcp.example.com/mcp")

        let refreshed = try await MCPSignIn.refresh(tokens, plan: plan, client: client, session: session)
        #expect(refreshed.access == "at-2")
        #expect(refreshed.refresh == "rt-1")
    }

    @Test func wellKnownAddressesGoBeforeThePath() {
        #expect(MCPSignIn.wellKnown("oauth-protected-resource", for: URL(string: "https://x.example.com/mcp")!).absoluteString
            == "https://x.example.com/.well-known/oauth-protected-resource/mcp")
        #expect(MCPSignIn.wellKnown("oauth-authorization-server", for: URL(string: "https://auth.example.com")!).absoluteString
            == "https://auth.example.com/.well-known/oauth-authorization-server")
    }
}
