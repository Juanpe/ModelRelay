import Foundation
import Testing
@testable import ModelRelay

/// Runs Apple's on-device model for real (APIs stay fake). Opt in with
/// `RELAY_LIVE=1 swift test --filter LiveAppleTests`; needs Apple Intelligence.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RELAY_LIVE"] != nil))
struct LiveAppleTests {
    @Test func onDeviceModelCallsAToolAndUsesItsAnswer() async throws {
        let server = FakeServer(json: #"{"city": "Lisbon", "temperature_c": 23, "sky": "sunny"}"#)
        let runner = WorkflowRunner(requests: server)
        let weather = AgentTool(name: "getWeather", description: "Gets the current weather for a city.",
                                parameters: [Field("city", .text, description: "City name")],
                                request: HTTPRequest(url: "https://api.example.com/weather?q={{args.city}}"))
        let workflow = Workflow(name: "Weather", steps: [
            Step("answer", .agent(instruction: "Answer the question. Use getWeather for weather questions.",
                                  tools: [weather]), model: .appleOnDevice),
        ])
        let report = try await runner.run(workflow, input: .text("What's the weather like in Lisbon right now?"))
        print("LIVE answer:", report.output.textValue, "| calls:", report.records.first?.toolCalls ?? [],
              "| sent:", server.requests.map(\.url.absoluteString))
        #expect(report.records.first?.toolCalls == ["getWeather"])
        #expect(report.output.textValue.contains("23"))
    }
}
