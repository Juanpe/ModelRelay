import Foundation
import Testing
@testable import ModelRelay

@Suite struct WorkflowRunnerTests {
    @Test func extractReturnsTypedFields() async throws {
        let model = ScriptedModel("small", replies: [#"{"merchant": "Blue Bottle Coffee", "total": 8.3}"#])
        let runner = WorkflowRunner(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Receipt", steps: [
            Step("expense", .extract(instruction: "Read the receipt.", fields: [
                Field("merchant", .text), Field("total", .number),
            ]), model: "small"),
        ])
        let report = try await runner.run(workflow, input: .text("BLUE BOTTLE ... TOTAL 8.30"))
        #expect(report.output["merchant"] == .text("Blue Bottle Coffee"))
        #expect(report.output["total"] == .number(8.3))
        #expect(report.records.map(\.model) == ["small"])
    }

    @Test func classifyDrivesTheBranchAndReportsSkippedSteps() async throws {
        let model = ScriptedModel("small", replies: [#""urgent""#, "Reply sent."])
        let runner = WorkflowRunner(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Triage", steps: [
            Step("label", .classify(instruction: "Is this urgent?", labels: ["urgent", "later"]), model: "small"),
            Step("route", .ifEquals(reference: "label", value: "urgent",
                                    then: [Step("reply", .prompt(instruction: "Write a reply."), input: "input", model: "small")],
                                    otherwise: [Step("note", .template("Later: {{input}}"))])),
        ])
        let report = try await runner.run(workflow, input: .text("Server is down"))
        #expect(report.output == .text("Reply sent."))
        #expect(report.records.first { $0.step == "note" }?.skipped == true)
    }

    @Test func parallelMergesResultsByStepName() async throws {
        let summary = ScriptedModel("a", replies: ["Short summary."])
        let tone = ScriptedModel("b", replies: [#""positive""#])
        let runner = WorkflowRunner(catalog: .scripted(["a": summary, "b": tone]))
        let workflow = Workflow(name: "Both", steps: [
            Step("both", .parallel([
                Step("summary", .prompt(instruction: "Summarize."), model: "a"),
                Step("tone", .classify(instruction: "Tone?", labels: ["positive", "negative"]), model: "b"),
            ])),
            Step("card", .template("{{summary}} ({{both.tone}})")),
        ])
        let report = try await runner.run(workflow, input: .text("Great launch today."))
        #expect(report.output == .text("Short summary. (positive)"))
    }

    @Test func fallbackRunsOnceWhenThePrimaryFails() async throws {
        let small = ScriptedModel("small", replies: [nil])
        let bigger = ScriptedModel("bigger", replies: ["Done."])
        let runner = WorkflowRunner(catalog: .scripted(["small": small, "bigger": bigger]))
        let workflow = Workflow(name: "Retry", steps: [
            Step("answer", .prompt(instruction: "Answer."), model: "small", fallback: "bigger"),
        ])
        let report = try await runner.run(workflow, input: .text("Q"))
        #expect(report.output == .text("Done."))
        #expect(report.records.first?.usedFallback == true)
        #expect(small.callCount == 1 && bigger.callCount == 1)
    }

    @Test func failureWithoutFallbackNamesTheStep() async throws {
        let runner = WorkflowRunner(catalog: .scripted(["small": ScriptedModel("small", replies: [nil])]))
        let workflow = Workflow(name: "Fail", steps: [Step("answer", .prompt(instruction: "Answer."), model: "small")])
        await #expect {
            try await runner.run(workflow, input: .text("Q"))
        } throws: { ($0 as? RelayError).map { if case .stepFailed("answer", _) = $0 { true } else { false } } ?? false }
    }

    @Test func aLabelOutsideTheListGoesToTheFallback() async throws {
        let small = ScriptedModel("small", replies: ["maybe"])
        let bigger = ScriptedModel("bigger", replies: ["Later"])
        let runner = WorkflowRunner(catalog: .scripted(["small": small, "bigger": bigger]))
        let workflow = Workflow(name: "Label", steps: [
            Step("label", .classify(instruction: "Urgent?", labels: ["urgent", "later"]), model: "small", fallback: "bigger"),
        ])
        let report = try await runner.run(workflow, input: .text("Newsletter"))
        #expect(report.output == .text("later"))
        #expect(report.records.first?.usedFallback == true)
    }

    /// Found benchmarking Qwen3 1.7B: one extraction ran for 150 s and blocked
    /// the workflow. A slow call now times out and goes to the fallback.
    @Test func aSlowModelTimesOutIntoTheFallback() async throws {
        let small = ScriptedModel("small", replies: ["<hang>"])
        let bigger = ScriptedModel("bigger", replies: ["Done."])
        let runner = WorkflowRunner(catalog: .scripted(["small": small, "bigger": bigger]), stepTimeout: .milliseconds(100))
        let workflow = Workflow(name: "Slow", steps: [
            Step("answer", .prompt(instruction: "Answer."), model: "small", fallback: "bigger"),
        ])
        let started = ContinuousClock.now
        let report = try await runner.run(workflow, input: .text("Q"))
        #expect(report.output == .text("Done."))
        #expect(report.records.first?.usedFallback == true)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func templatesSubstituteWithoutEvaluating() {
        let values: [String: Value] = ["total": .number(8), "x": .dictionary(["y": .text("ok")])]
        let rendered = Template.render("{{total}} / {{x.y}} / {{ missing }} / {{1+1}}") { values[$0] ?? values["x"]?[$0.replacingOccurrences(of: "x.", with: "")] }
        #expect(rendered == "8 / ok /  / ")
    }

    @Test func workflowsRoundTripAsJSON() throws {
        let workflow = Workflow(name: "Receipt", steps: [
            Step("expense", .extract(instruction: "Read.", fields: [Field("tags", .list(.choice(["food", "travel"])))]),
                 model: .appleOnDevice, fallback: "mlx:qwen"),
            Step("both", .parallel([Step("t", .template("{{expense.tags}}"))])),
        ])
        let data = try JSONEncoder().encode(workflow)
        #expect(try JSONDecoder().decode(Workflow.self, from: data) == workflow)
        #expect(String(decoding: data, as: UTF8.self).contains(#""model":"apple.on-device""#))
    }
}

@Suite struct SwitchStepTests {
    private func workflow() -> Workflow {
        Workflow(name: "Inbox", steps: [
            Step("kind", .template("{{input}}")),
            Step("route", .switchOn(reference: "kind", cases: [
                SwitchCase("urgent", steps: [Step("alert", .template("Now: {{input}}"))]),
                SwitchCase("meeting", steps: [Step("invite", .template("Meet: {{input}}"))]),
            ], otherwise: [Step("later", .template("Later: {{input}}"))])),
        ])
    }

    @Test func runsTheMatchingCase() async throws {
        let report = try await WorkflowRunner().run(workflow(), input: .text(" Meeting "))
        #expect(report.output == .text("Meet:  Meeting "))
        #expect(Set(report.records.filter(\.skipped).map(\.step)) == ["alert", "later"])
    }

    @Test func fallsBackToOtherwise() async throws {
        let report = try await WorkflowRunner().run(workflow(), input: .text("newsletter"))
        #expect(report.output == .text("Later: newsletter"))
        #expect(Set(report.records.filter(\.skipped).map(\.step)) == ["alert", "invite"])
    }

    @Test func roundTripsThroughJSON() throws {
        let step = workflow().steps[1]
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    }
}
