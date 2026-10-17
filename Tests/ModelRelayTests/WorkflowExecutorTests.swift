import Foundation
import Synchronization
import Testing
@testable import ModelRelay

@Suite struct WorkflowExecutorTests {
    @Test func extractReturnsTypedFields() async throws {
        let model = ScriptedModel("small", replies: [#"{"merchant": "Blue Bottle Coffee", "total": 8.3}"#])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Receipt", steps: [
            Step("expense", .extract(instruction: "Read the receipt.", fields: [
                Field("merchant", .text), Field("total", .number),
            ]), model: "small"),
        ])
        let report = try await executor.run(workflow, input: .text("BLUE BOTTLE ... TOTAL 8.30"))
        #expect(report.output["merchant"] == .text("Blue Bottle Coffee"))
        #expect(report.output["total"] == .number(8.3))
        #expect(report.records.map(\.model) == ["small"])
    }

    @Test func classifyDrivesTheBranchAndReportsSkippedSteps() async throws {
        let model = ScriptedModel("small", replies: [#""urgent""#, "Reply sent."])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Triage", steps: [
            Step("label", .classify(instruction: "Is this urgent?", labels: ["urgent", "later"]), model: "small"),
            Step("route", .ifEquals(reference: "label", value: "urgent",
                                    then: [Step("reply", .prompt(instruction: "Write a reply."), input: "input", model: "small")],
                                    otherwise: [Step("note", .template("Later: {{input}}"))])),
        ])
        let report = try await executor.run(workflow, input: .text("Server is down"))
        #expect(report.output == .text("Reply sent."))
        #expect(report.records.first { $0.step == "note" }?.skipped == true)
    }

    @Test func parallelMergesResultsByStepName() async throws {
        let summary = ScriptedModel("a", replies: ["Short summary."])
        let tone = ScriptedModel("b", replies: [#""positive""#])
        let executor = WorkflowExecutor(catalog: .scripted(["a": summary, "b": tone]))
        let workflow = Workflow(name: "Both", steps: [
            Step("both", .parallel([
                Step("summary", .prompt(instruction: "Summarize."), model: "a"),
                Step("tone", .classify(instruction: "Tone?", labels: ["positive", "negative"]), model: "b"),
            ])),
            Step("card", .template("{{summary}} ({{both.tone}})")),
        ])
        let report = try await executor.run(workflow, input: .text("Great launch today."))
        #expect(report.output == .text("Short summary. (positive)"))
    }

    @Test func fallbackRunsOnceWhenThePrimaryFails() async throws {
        let small = ScriptedModel("small", replies: [nil])
        let bigger = ScriptedModel("bigger", replies: ["Done."])
        let executor = WorkflowExecutor(catalog: .scripted(["small": small, "bigger": bigger]))
        let workflow = Workflow(name: "Retry", steps: [
            Step("answer", .prompt(instruction: "Answer."), model: "small", fallback: "bigger"),
        ])
        let report = try await executor.run(workflow, input: .text("Q"))
        #expect(report.output == .text("Done."))
        #expect(report.records.first?.usedFallback == true)
        #expect(small.callCount == 1 && bigger.callCount == 1)
    }

    @Test func failureWithoutFallbackNamesTheStep() async throws {
        let executor = WorkflowExecutor(catalog: .scripted(["small": ScriptedModel("small", replies: [nil])]))
        let workflow = Workflow(name: "Fail", steps: [Step("answer", .prompt(instruction: "Answer."), model: "small")])
        await #expect {
            try await executor.run(workflow, input: .text("Q"))
        } throws: { ($0 as? RelayError).map { if case .operationFailed("answer", _) = $0 { true } else { false } } ?? false }
    }

    @Test func aLabelOutsideTheListGoesToTheFallback() async throws {
        let small = ScriptedModel("small", replies: ["maybe"])
        let bigger = ScriptedModel("bigger", replies: ["Later"])
        let executor = WorkflowExecutor(catalog: .scripted(["small": small, "bigger": bigger]))
        let workflow = Workflow(name: "Label", steps: [
            Step("label", .classify(instruction: "Urgent?", labels: ["urgent", "later"]), model: "small", fallback: "bigger"),
        ])
        let report = try await executor.run(workflow, input: .text("Newsletter"))
        #expect(report.output == .text("later"))
        #expect(report.records.first?.usedFallback == true)
    }

    /// Found benchmarking Qwen3 1.7B: one extraction ran for 150 s and blocked
    /// the workflow. A slow call now times out and goes to the fallback.
    @Test func aSlowModelTimesOutIntoTheFallback() async throws {
        let small = ScriptedModel("small", replies: ["<hang>"])
        let bigger = ScriptedModel("bigger", replies: ["Done."])
        let executor = WorkflowExecutor(catalog: .scripted(["small": small, "bigger": bigger]), stepTimeout: .milliseconds(100))
        let workflow = Workflow(name: "Slow", steps: [
            Step("answer", .prompt(instruction: "Answer."), model: "small", fallback: "bigger"),
        ])
        let started = ContinuousClock.now
        let report = try await executor.run(workflow, input: .text("Q"))
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
            Step(
                "expense",
                .extract(instruction: "Read.", fields: [Field("tags", .list(.choice(["food", "travel"])))]),
                model: .appleOnDevice,
                fallback: "mlx:qwen"
            ),
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
        let report = try await WorkflowExecutor().run(workflow(), input: .text(" Meeting "))
        #expect(report.output == .text("Meet:  Meeting "))
        #expect(Set(report.records.filter(\.skipped).map(\.step)) == ["alert", "later"])
    }

    @Test func fallsBackToOtherwise() async throws {
        let report = try await WorkflowExecutor().run(workflow(), input: .text("newsletter"))
        #expect(report.output == .text("Later: newsletter"))
        #expect(Set(report.records.filter(\.skipped).map(\.step)) == ["alert", "invite"])
    }

    @Test func roundTripsThroughJSON() throws {
        let step = workflow().steps[1]
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    }
}

@Suite struct DecideStepTests {
    private let questions = [
        Question("damaged", "Does the customer report a damaged item?", .yesNo),
        Question("queue", "Which team should handle it?", .choice([.init("billing"), .init("shipping")])),
        Question("urgency", "How urgent is it?", .score(["low", "medium", "high"])),
    ]

    @Test func languageModelsAnswerWithAGuidedSchema() async throws {
        let model = ScriptedModel("small", replies: [#"{"damaged": true, "queue": "shipping", "urgency": "high"}"#])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let workflow = Workflow(name: "Ticket", steps: [Step("ticket", .decide(questions: questions), model: "small")])
        let report = try await executor.run(workflow, input: .text("The screen arrived broken."))
        #expect(report.output["damaged"] == .bool(true))
        #expect(report.output["queue"] == .text("shipping"))
        #expect(report.output["urgency"] == .text("high"))
        #expect(report.output["confidence"] == nil)
    }

    @Test func decisionModelsAddConfidence() async throws {
        struct Fixed: DecisionModel {
            func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
                [Answer(name: "damaged", result: .yesNo(true), confidence: 0.95),
                 Answer(name: "queue", result: .choice("shipping"), confidence: 0.81),
                 Answer(name: "urgency", result: .score(1.3, level: "medium"), confidence: 0.62)]
            }
        }
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering(decisions: "jev") { Fixed() })
        let workflow = Workflow(name: "Ticket", steps: [Step("ticket", .decide(questions: questions), model: "jev")])
        let report = try await executor.run(workflow, input: .text("Broken screen."))
        #expect(report.output["urgency"] == .text("medium"))
        #expect(report.output["scores"]?["urgency"] == .number(1.3))
        #expect(report.output["confidence"]?["damaged"] == .number(0.95))
    }

    @Test func aFailingDecisionModelFallsBackToALanguageModel() async throws {
        struct Down: DecisionModel {
            func decide(_ questions: [Question], about input: String) async throws -> [Answer] { throw URLError(.notConnectedToInternet) }
        }
        let local = ScriptedModel("local", replies: [#"{"damaged": false, "queue": "billing", "urgency": "low"}"#])
        let catalog = ModelCatalog.scripted(["local": local]).registering(decisions: "jev") { Down() }
        let workflow = Workflow(name: "Ticket", steps: [
            Step("ticket", .decide(questions: questions), model: "jev", fallback: "local"),
        ])
        let report = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .text("Charged twice."))
        #expect(report.output["queue"] == .text("billing"))
        #expect(report.records.first?.usedFallback == true)
    }
}

@Suite struct DecideValidationTests {
    @Test func incompleteQuestionsFailBeforeAnythingIsSent() async throws {
        let model = ScriptedModel("small", replies: ["{}"])
        let executor = WorkflowExecutor(catalog: .scripted(["small": model]))
        let cases: [([Question], String)] = [
            ([Question("urgent", "", .yesNo)], "Question “urgent” has no question text"),
            ([Question("team", "Which?", .choice([]))], "Question “team” needs between 1 and 255 options"),
            ([Question("level", "How?", .score(["only"]))], "Question “level” needs between 2 and 10 levels"),
            ([Question("a", "A?", .yesNo), Question("a", "B?", .yesNo)], "Two questions share a name"),
        ]
        for (questions, reason) in cases {
            let workflow = Workflow(name: "D", steps: [Step("decision", .decide(questions: questions), model: "small")])
            await #expect(throws: WorkflowValidationError(issues: [.init(step: "decision", kind: .invalidSchema, detail: reason)])) {
                try await executor.run(workflow, input: .text("the bill is pending"))
            }
        }
        #expect(model.callCount == 0)
    }
}

@Suite struct TemplateListTests {
    @Test func listsReadAsCommaSeparatedInText() async throws {
        let workflow = Workflow(name: "T", steps: [Step("line", .template("With {{input}}"))])
        let report = try await WorkflowExecutor().run(workflow, input: .list([.text("Ana"), .text("Luis")]))
        #expect(report.output == .text("With Ana, Luis"))
    }
}

@Suite struct StepStreamTests {
    @Test func stepsAreReportedAsTheyFinishEvenWhenALaterOneFails() async throws {
        let seen = Mutex<[StepRecord]>([])
        let workflow = Workflow(name: "W", steps: [
            Step("first", .template("one")),
            Step("both", .parallel([Step("a", .template("A")), Step("b", .template("B"))])),
            Step.custom("broken") { _ in throw InvalidOutput(reason: "runtime failure") },
        ])
        await #expect(throws: expectedOperationFailure(step: "broken", reason: "runtime failure", category: .invalidOutput, uncertain: true)) {
            try await WorkflowExecutor().stream(workflow, input: .text(""))
                .observing(onStep: { record in seen.withLock { $0.append(record) } })
        }
        // The steps that finished, then the one the run stopped at, with why.
        #expect(seen.withLock { Set($0.map(\.step)) } == ["first", "a", "b", "broken"])
        #expect(seen.withLock { $0.last }?.failure == "runtime failure")
        #expect(seen.withLock { $0.filter { $0.failure != nil }.count } == 1)
    }
}

@Suite struct ClassifyWithDecisionModelTests {
    struct Picker: DecisionModel {
        func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
            #expect(input == "Server is down")
            return [Answer(name: questions[0].name, result: .choice("urgent"), confidence: 0.9)]
        }
    }

    @Test func classifyRunsOnADecisionModel() async throws {
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering(decisions: "jev") { Picker() })
        let workflow = Workflow(name: "T", steps: [
            Step("label", .classify(instruction: "Is it urgent?", labels: ["urgent", "later"]), model: "jev"),
        ])
        #expect(try await executor.run(workflow, input: .text("Server is down")).output == .text("urgent"))
    }

    @Test func textStepsExplainADecisionModelCantWrite() async throws {
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering(decisions: "jev") { Picker() })
        let workflow = Workflow(name: "T", steps: [Step("ask", .prompt(instruction: "Hi"), model: "jev")])
        await #expect(throws: WorkflowValidationError.self) { try await executor.run(workflow, input: .text("x")) }
    }
}
