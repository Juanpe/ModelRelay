import Foundation
import Testing
@testable import ModelRelay

@Suite struct CancellationTests {
    static let modelSteps: [Step.Kind] = [
        .prompt(instruction: "Answer."),
        .extract(instruction: "Extract.", fields: [Field("name", .text)]),
        .classify(instruction: "Classify.", labels: ["yes", "no"]),
        .agent(instruction: "Answer.", tools: []),
        .decide(questions: [Question("ok", "Is it OK?", .yesNo)]),
        .readImage(instruction: "Read."),
    ]

    @Test(arguments: modelSteps, [false, true])
    func cancellingAModelAttemptPropagatesWithoutStartingAnother(_ kind: Step.Kind, duringFallback: Bool) async throws {
        let slow = ScriptedModel("slow", replies: ["<hang>"])
        let primary = duringFallback ? ScriptedModel("primary", replies: [nil]) : slow
        let fallback = duringFallback ? slow : ScriptedModel("fallback", replies: ["Must not run"])
        let workflow = Workflow("Cancel") {
            Step("answer", kind, model: "primary", fallback: "fallback")
        }
        let runner = WorkflowRunner(catalog: .scripted(["primary": primary, "fallback": fallback]))
        let input: Value = if case .readImage = kind {
            .image(ImageValue(data: picture(), contentType: "image/png"))
        } else { .text("Original") }
        let task = Task { try await runner.run(workflow, input: input) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if slow.callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(slow.callCount == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fallback.callCount == (duringFallback ? 1 : 0))
    }
}
