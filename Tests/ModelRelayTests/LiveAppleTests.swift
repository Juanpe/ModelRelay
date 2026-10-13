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

    @Test func onDeviceModelAnswersDecideQuestions() async throws {
        let workflow = Workflow(name: "Ticket", steps: [Step("ticket", .decide(questions: [
            Question("damaged", "Does the customer report a damaged item?", .yesNo),
            Question("queue", "Which team should handle it?", .choice([.init("billing", description: "Refunds and payments"),
                                                                     .init("shipping", description: "Delivery and damaged items")])),
            Question("urgency", "How urgent is it?", .score(["low", "medium", "high"])),
        ]), model: .appleOnDevice)])
        let report = try await WorkflowRunner().run(workflow, input: .text("The package arrived with a broken screen. I need it for work tomorrow."))
        print("LIVE decide:", report.output.textValue.replacingOccurrences(of: "\n", with: " | "), "|", report.duration)
        #expect(report.output["damaged"] == .bool(true))
        #expect(report.output["queue"] == .text("shipping"))
    }
}
