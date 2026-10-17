import Foundation
import Synchronization
import Testing
@testable import ModelRelay

/// A tool server with a fixed tool list that keeps every call.
private final class FakeToolServer: ToolServerConnector, ToolServerConnection {
    let list: [ServerTool]
    let reply: Value
    private let calls = Mutex<[(tool: String, arguments: [String: Value])]>([])
    var made: [(tool: String, arguments: [String: Value])] { calls.withLock { $0 } }

    init(_ list: [ServerTool], reply: Value = .dictionary(["id": .text("ISS-1")])) {
        self.list = list
        self.reply = reply
    }

    func connect(to kit: ToolKit) async throws -> any ToolServerConnection { self }
    func tools() async throws -> [ServerTool] { list }
    func call(_ tool: String, arguments: [String: Value]) async throws -> Value {
        calls.withLock { $0.append((tool, arguments)) }
        return reply
    }
}

private final class Asked: Sendable {
    private let seen = Mutex<[String]>([])
    var requests: [String] { seen.withLock { $0 } }
    func policy(_ answer: Bool) -> WritePolicy {
        .ask { request in
            self.seen.withLock { $0.append(request.description) }
            return answer
        }
    }
}

@Suite struct ToolServerTests {
    private let kit = ToolKit(id: "linear", name: "Linear", tools: [], server: ToolServer(url: "https://mcp.example.com/mcp"))
    private let createIssue = ServerTool(
        name: "create_issue",
        description: "Creates an issue.",
        parameters: [Field("title", .text), Field("priority", .number), Field("urgent", .bool),
                     Field("labels", .list(.text)), Field("notes", .text)],
        required: ["title"],
        changesSomething: true
    )
    private let search = ServerTool(
        name: "search.issues",
        description: "Finds issues.",
        parameters: [Field("query", .text)],
        required: ["query"],
        changesSomething: false
    )

    @Test func agentsCallServerToolsAndWritesAskFirst() async throws {
        let server = FakeToolServer([createIssue, search])
        let model = ScriptedModel("small", replies: [#"<tool:create_issue>{"title": "Fix login"}"#, "Created ISS-1."])
        let asked = Asked()
        let executor = WorkflowExecutor(
            catalog: .scripted(["small": model]),
            writePolicy: asked.policy(true),
            toolKits: [kit],
            toolServers: server
        )
        let workflow = Workflow(name: "File", steps: [
            Step("answer", .agent(instruction: "File it.", tools: [], kits: ["linear"]), model: "small"),
        ])
        let report = try await executor.run(workflow, input: .text("Login is broken"))
        #expect(report.output == .text("Created ISS-1."))
        #expect(report.records.first?.toolCalls == ["create_issue"])
        #expect(server.made.first?.arguments["title"] == .text("Fix login"))
        #expect(asked.requests.first?.contains("create_issue") == true)
    }

    @Test func readOnlyToolsDontAskAndNamesAreMadeSafe() async throws {
        let server = FakeToolServer([search], reply: .list([.text("ISS-1")]))
        let model = ScriptedModel("small", replies: [#"<tool:search_issues>{"query": "login"}"#, "Found one."])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]), writePolicy: .deny, toolKits: [kit], toolServers: server)
        let workflow = Workflow(name: "Find", steps: [
            Step("answer", .agent(instruction: "Find it.", tools: [], kits: ["linear"]), model: "small"),
        ])
        let report = try await executor.run(workflow, input: .text("login"))
        #expect(report.output == .text("Found one."))
        #expect(server.made.first?.tool == "search.issues")
    }

    @Test func useAToolSendsTypedArguments() async throws {
        let server = FakeToolServer([createIssue])
        let workflow = Workflow(name: "File", steps: [
            Step("file", .useTool(kit: "linear", tool: "create_issue", arguments: [
                "title": "Bug: {{input}}", "priority": "2", "urgent": "yes", "labels": "bug\nlogin", "notes": "  ",
            ])),
            Step("say", .template("Filed {{file.id}}")),
        ])
        let executor = WorkflowExecutor(writePolicy: .allow, toolKits: [kit], toolServers: server)
        let report = try await executor.run(workflow, input: .text("login"))
        #expect(report.output == .text("Filed ISS-1"))
        let call = try #require(server.made.first)
        #expect(call.arguments == ["title": .text("Bug: login"), "priority": .number(2), "urgent": .bool(true),
                                   "labels": .list([.text("bug"), .text("login")])])
        #expect(report.records.first?.input?.contains("create_issue") == true)
    }

    @Test func useAToolNeedsPermissionToChangeSomething() async throws {
        let server = FakeToolServer([createIssue])
        let workflow = Workflow(name: "File", steps: [
            Step("file", .useTool(kit: "linear", tool: "create_issue", arguments: ["title": "x"])),
        ])
        await #expect(throws: RelayError.writeNotAllowed(step: "file")) {
            try await WorkflowExecutor(toolKits: [kit], toolServers: server).run(workflow, input: .text(""))
        }
        #expect(server.made.isEmpty)
    }

    @Test func exhaustedMCPBudgetNeverCallsTheToolOrAsksForWriteApproval() async {
        let server = FakeToolServer([createIssue])
        let asked = Asked()
        let workflow = Workflow("Bounded MCP") { Step.useTool("file", kit: kit.id, tool: "create_issue", arguments: ["title": "x"]) }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(writePolicy: asked.policy(true), toolKits: [kit], toolServers: server)
                .run(workflow, input: .null, limits: .init(maxToolCalls: 0))
        }
        #expect(server.made.isEmpty)
        #expect(asked.requests.isEmpty)
    }

    @Test func nativeMCPAgentCallsShareTheBudgetWithDirectToolSteps() async {
        let server = FakeToolServer([search])
        let model = ScriptedModel("model", replies: [#"<tool:search_issues>{"query":"x"}"#, "unused"])
        let workflow = Workflow("MCP budget") {
            Step.useTool("first", kit: kit.id, tool: search.name, arguments: ["query": "x"])
            Step.agent("second", "Find", kits: [kit.id], model: "model")
        }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(catalog: .scripted(["model": model]), toolKits: [kit], toolServers: server)
                .run(workflow, input: .null, limits: .init(maxToolCalls: 1))
        }
        #expect(server.made.count == 1)
    }

    @Test func useAToolRunsRequestToolsFromAKit() async throws {
        let weather = ToolKit(id: "weather", name: "Weather", tools: [
            AgentTool(
                name: "forecast",
                description: "Forecast.",
                parameters: [Field("city", .text)],
                request: HTTPRequest(url: "https://api.example.com/w?q={{args.city}}")
            ),
        ])
        let api = FakeServer(json: #"{"temp": 19}"#)
        let workflow = Workflow(name: "W", steps: [
            Step("now", .useTool(kit: "weather", tool: "forecast", arguments: ["city": "{{input}}"])),
        ])
        let report = try await WorkflowExecutor(requests: api, toolKits: [weather]).run(workflow, input: .text("Lisbon"))
        #expect(report.output["temp"] == .number(19))
        #expect(api.requests.first?.url.absoluteString == "https://api.example.com/w?q=Lisbon")
    }

    @Test func missingToolsAndServersFailClearly() async throws {
        let workflow = Workflow(name: "File", steps: [Step("file", .useTool(kit: "linear", tool: "nope", arguments: [:]))])
        await #expect(throws: RelayError.stepFailed(step: "file", reason: "Linear has no tool “nope”")) {
            try await WorkflowExecutor(toolKits: [kit], toolServers: FakeToolServer([createIssue])).run(workflow, input: .text(""))
        }
        await #expect(throws: RelayError.stepFailed(step: "file", reason: "tool servers can't be reached here")) {
            try await WorkflowExecutor(toolKits: [kit]).run(workflow, input: .text(""))
        }
    }

    @Test func renamingAStepUpdatesToolArguments() {
        var workflow = Workflow(name: "W", steps: [
            Step("summary", .template("x")),
            Step("file", .useTool(kit: "linear", tool: "create_issue", arguments: ["title": "{{summary}}"])),
        ])
        let renamed = workflow.renameStep(from: "summary", to: "gist")
        #expect(renamed)
        #expect(workflow.steps[1].kind == .useTool(kit: "linear", tool: "create_issue", arguments: ["title": "{{gist}}"]))
        #expect(workflow.referenceIssues.isEmpty)
    }

    @Test func numbersAreSentInTheirShortestForm() throws {
        let data = try JSONSerialization.data(withJSONObject: Value.dictionary(["amount": .number(4.5 + 3.8)]).jsonObject)
        #expect(String(decoding: data, as: UTF8.self) == #"{"amount":8.3}"#)
    }

    @Test func toolKitsWithoutAServerStillDecode() throws {
        let json = #"{"id":"w","name":"Weather","summary":"","tools":[]}"#
        let kit = try JSONDecoder().decode(ToolKit.self, from: Data(json.utf8))
        #expect(kit.server == nil)
    }
}
