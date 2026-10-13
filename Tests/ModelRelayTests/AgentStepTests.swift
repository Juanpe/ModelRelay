import Foundation
import Testing
@testable import ModelRelay

@Suite struct AgentStepTests {
    private let weather = AgentTool(
        name: "weather", description: "Current weather for a city.",
        parameters: [Field("city", .text)],
        request: HTTPRequest(url: "https://api.example.com/weather?q={{args.city}}",
                             headers: [.init("Authorization", "Bearer {{secret.KEY}}")]))

    private let createTask = AgentTool(
        name: "create_task", description: "Create a task.",
        parameters: [Field("title", .text)],
        request: HTTPRequest(.post, url: "https://api.example.com/tasks", body: #"{"title": "{{args.title}}"}"#))

    @Test func agentCallsAToolAndAnswersWithItsOutput() async throws {
        let model = ScriptedModel("small", replies: [#"<tool:weather>{"city": "Lisbon"}"#, "It's 21 degrees in Lisbon."])
        let server = FakeServer(json: #"{"temp": 21}"#)
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: server,
                                    secrets: FakeSecrets(values: ["KEY": "k-test"]))
        let workflow = Workflow(name: "Ask", steps: [
            Step("answer", .agent(instruction: "Answer using the tools.", tools: [weather]), model: "small"),
        ])
        let report = try await runner.run(workflow, input: .text("Weather in Lisbon?"))

        #expect(report.output == .text("It's 21 degrees in Lisbon."))
        #expect(report.records.first?.toolCalls == ["weather"])
        let sent = try #require(server.requests.first)
        #expect(sent.url.absoluteString == "https://api.example.com/weather?q=Lisbon")
        #expect(sent.headers.first?.value == "Bearer k-test")
        // The model saw the tool's output, never the secret.
        #expect(model.prompts.last?.contains(#"[weather] {"temp":21}"#) == true)
        #expect(model.prompts.allSatisfy { !$0.contains("k-test") })
    }

    @Test func writeToolsFollowTheWritePolicy() async throws {
        let model = ScriptedModel("small", replies: [#"<tool:create_task>{"title": "Call mum"}"#, "Couldn't create it."])
        let server = FakeServer(json: #"{"id": 1}"#)
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: server)
        let workflow = Workflow(name: "Task", steps: [
            Step("do", .agent(instruction: "Create the task.", tools: [createTask]), model: "small"),
        ])
        // Denied by default: the call never reaches the server.
        _ = try? await runner.run(workflow, input: .text("Remind me to call mum"))
        #expect(server.requests.isEmpty)
    }

    @Test func toolCallsAreCapped() async throws {
        let loop = Array(repeating: Optional(#"<tool:weather>{"city": "Lisbon"}"#), count: 10)
        let model = ScriptedModel("small", replies: loop)
        let server = FakeServer(json: #"{"temp": 21}"#)
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: server,
                                    secrets: FakeSecrets(values: ["KEY": "k"]))
        let workflow = Workflow(name: "Loop", steps: [
            Step("answer", .agent(instruction: "Answer.", tools: [weather]), model: "small"),
        ])
        await #expect(throws: RelayError.self) {
            try await runner.run(workflow, input: .text("?"))
        }
        #expect(server.requests.count == AgentTool.maxCallsPerStep)
    }

    @Test func noFallbackAfterAToolRan() async throws {
        let first = ScriptedModel("small", replies: [#"<tool:create_task>{"title": "x"}"#, nil])
        let second = ScriptedModel("big", replies: ["Done."])
        let server = FakeServer(json: #"{"id": 1}"#)
        let runner = WorkflowRunner(catalog: .scripted(["small": first, "big": second]), requests: server,
                                    writePolicy: .allow)
        let workflow = Workflow(name: "Task", steps: [
            Step("do", .agent(instruction: "Create the task.", tools: [createTask]), model: "small", fallback: "big"),
        ])
        await #expect(throws: RelayError.self) {
            try await runner.run(workflow, input: .text("x"))
        }
        #expect(server.requests.count == 1)
        #expect(second.callCount == 0)
    }

    @Test func fallbackWhenNoToolRan() async throws {
        let first = ScriptedModel("small", replies: [nil])
        let second = ScriptedModel("big", replies: ["Hello."])
        let runner = WorkflowRunner(catalog: .scripted(["small": first, "big": second]), requests: FakeServer(json: "{}"))
        let workflow = Workflow(name: "Hi", steps: [
            Step("hi", .agent(instruction: "Say hello.", tools: [weather]), model: "small", fallback: "big"),
        ])
        let report = try await runner.run(workflow, input: .text(""))
        #expect(report.output == .text("Hello."))
        #expect(report.records.first?.usedFallback == true)
    }

    @Test func agentStepsRoundTripThroughJSON() throws {
        let step = Step("a", .agent(instruction: "Go.", tools: [weather, createTask]), model: .appleOnDevice)
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    }
}

@Suite struct AgentErrorTests {
    @Test func aFailedToolReadsClearly() async throws {
        let model = ScriptedModel("small", replies: [#"<tool:weather>{"city": "Lisbon"}"#, "unused"])
        let tool = AgentTool(name: "weather", description: "Weather.", parameters: [Field("city", .text)],
                             request: HTTPRequest(url: "https://api.example.com/w?q={{args.city}}"))
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: FakeServer(status: 503, json: "{}"))
        let workflow = Workflow(name: "W", steps: [Step("answer", .agent(instruction: "Answer.", tools: [tool]), model: "small")])
        await #expect(throws: RelayError.stepFailed(step: "answer", reason: "weather: The server answered HTTP 503")) {
            try await runner.run(workflow, input: .text("?"))
        }
    }
}

@Suite struct ToolKitTests {
    private let kit = ToolKit(id: "weather-api", name: "Weather", tools: [
        AgentTool(name: "weather", description: "Weather.", parameters: [Field("city", .text)],
                  request: HTTPRequest(url: "https://api.example.com/w?q={{args.city}}")),
    ])

    @Test func agentsUseToolsFromAKit() async throws {
        let model = ScriptedModel("small", replies: [#"<tool:weather>{"city": "Oslo"}"#, "Cold."])
        let server = FakeServer(json: #"{"temp": -2}"#)
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: server, toolKits: [kit])
        let workflow = Workflow(name: "W", steps: [
            Step("answer", .agent(instruction: "Answer.", tools: [], kits: ["weather-api"]), model: "small"),
        ])
        let report = try await runner.run(workflow, input: .text("Oslo?"))
        #expect(report.records.first?.toolCalls == ["weather"])
        #expect(server.requests.first?.url.absoluteString == "https://api.example.com/w?q=Oslo")
    }

    @Test func aMissingKitFailsClearly() async throws {
        let runner = WorkflowRunner(catalog: .scripted(["small": ScriptedModel("small", replies: ["x"])]))
        let workflow = Workflow(name: "W", steps: [
            Step("answer", .agent(instruction: "Answer.", tools: [], kits: ["gone"]), model: "small"),
        ])
        await #expect(throws: RelayError.stepFailed(step: "answer", reason: "the tool set “gone” isn't available")) {
            try await runner.run(workflow, input: .text(""))
        }
    }

    @Test func olderAgentStepsStillDecode() throws {
        let json = #"{"name":"a","kind":{"agent":{"instruction":"Go.","tools":[]}}}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(json.utf8))
        #expect(step.kind == .agent(instruction: "Go.", tools: [], kits: nil))
    }
}
