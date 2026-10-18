import Foundation
import ModelRelay
import Testing

@Suite struct WorkflowBuilderTests {
    @Test func builderPreservesTheExistingTreeAndJSON() throws {
        let id = UUID()
        let built = Workflow(
            name: "Article",
            id: id,
            output: "result"
        ) {
            Step.prompt("summary", "Summarize.", model: "writer", fallback: .appleOnDevice)
            Step.parallel("analysis", input: "input") {
                Step.classify("tone", "Tone?", labels: ["positive", "negative"], model: "small")
                Step("headline", .prompt(instruction: "Headline?"), model: "writer")
            }
            Step.template("result", "{{summary}} {{analysis.tone}}")
        }
        let original = Workflow(id: id, name: "Article", steps: [
            Step("summary", .prompt(instruction: "Summarize."), model: "writer", fallback: .appleOnDevice),
            Step("analysis", .parallel([
                Step("tone", .classify(instruction: "Tone?", labels: ["positive", "negative"]), model: "small"),
                Step("headline", .prompt(instruction: "Headline?"), model: "writer"),
            ]), input: "input"),
            Step("result", .template("{{summary}} {{analysis.tone}}")),
        ], output: "result")

        #expect(built == original)
        #expect(built.referenceIssues.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(built) == encoder.encode(original))
        #expect(try JSONDecoder().decode(Workflow.self, from: encoder.encode(built)) == original)
    }

    @Test func namedAndUnlabeledInitializersMatchAndEvaluateBuildersOnce() {
        let id = UUID()
        var evaluations = 0
        func result() -> Step {
            evaluations += 1
            return .template("result", "{{input}}")
        }
        let named = Workflow(
            name: "Analyze article",
            id: id,
            output: "result"
        ) {
            result()
        }
        #expect(evaluations == 1)
        let unlabeled = Workflow("Analyze article", id: id, output: "result") {
            result()
        }
        #expect(evaluations == 2)
        #expect(named == unlabeled)
        #expect(Workflow(name: "Empty") {}.steps.isEmpty)
    }

    @Test func constructionSupportsArraysConditionsLoopsAndSwitches() {
        let extras = [Step.template("existing", "Existing")]
        let optional: Step? = Step.template("optional", "Optional")
        let absent: Step? = nil
        let selected = "short"
        let built = Workflow("Composition") {
            extras
            if let optional { optional }
            if let absent { absent }
            if selected == "short" {
                Step.template("selected", "Short")
            } else {
                Step.template("unused", "Long")
            }
            for index in 0 ..< 2 {
                Step.template("item_\(index)", "\(index)")
            }
            switch selected {
            case "short": Step.template("switch", "Short")
            default: Step.template("unused_switch", "Long")
            }
            if #available(macOS 999, iOS 999, visionOS 999, *) {
                Step.template("future", "Future")
            } else {
                Step.template("current", "Current")
            }
        }
        #expect(built.steps.map(\.name) == ["existing", "optional", "selected", "item_0", "item_1", "switch", "current"])
        #expect(Workflow("Empty") {}.steps.isEmpty)
        #expect(Step.parallel("empty") {}.kind == .parallel([]))
        #expect(WorkflowBuilder.buildLimitedAvailability(extras) == extras)
    }

    @Test func constructionRunsImmediatelyAndDoesNotChangeWhenConfigurationChanges() {
        var enabled = true
        var evaluations = 0
        func configuredStep() -> Step {
            evaluations += 1
            return .template("configured", "Yes")
        }
        let built = Workflow("Snapshot") {
            if enabled { configuredStep() }
        }
        enabled = false
        #expect(evaluations == 1)
        #expect(built.steps == [.template("configured", "Yes")])
        #expect(!enabled)
    }

    @Test func fieldBuilderSupportsCompositionAndKeepsSchemaMetadata() {
        let shared = [Field("merchant", .text, description: "Who sold it")]
        let includeTotal = true
        let optional: Field? = Field("paid", .bool)
        let absent: Field? = nil
        let kind = "currency"
        let built = Step.extract("expense", instruction: "Read.", input: "receipt", model: "primary", fallback: "backup") {
            shared
            if includeTotal { Field("total", .number) }
            if !includeTotal { Field("absent", .text) }
            if let optional { optional }
            if let absent { absent }
            if includeTotal { Field("tags", .list(.text)) } else { Field("other", .text) }
            for name in ["note", "reference"] { Field(name, .text) }
            switch kind {
            case "currency": Field("currency", .choice(["EUR", "USD"]))
            default: Field("other_currency", .text)
            }
            if #available(macOS 999, iOS 999, visionOS 999, *) {
                Field("future", .text)
            }
        }
        let fields = shared + [Field("total", .number), Field("paid", .bool), Field("tags", .list(.text)),
                               Field("note", .text), Field("reference", .text), Field("currency", .choice(["EUR", "USD"]))]
        #expect(built == Step("expense", .extract(instruction: "Read.", fields: fields), input: "receipt", model: "primary", fallback: "backup"))
        #expect(Step.extract("empty", instruction: "Read.", model: "primary") {}.kind == .extract(instruction: "Read.", fields: []))
        #expect(FieldBuilder.buildLimitedAvailability(shared) == shared)
    }

    @Test func helpersPreserveEveryStepKindAndItsOptions() {
        let tool = AgentTool(name: "lookup", description: "Look up a value", request: HTTPRequest(url: "https://example.test"))
        let question = Question("urgent", "Is it urgent?", .yesNo)
        let request = HTTPRequest(.post, url: "https://example.test", body: "{{input}}")
        let built: [Step] = [
            .prompt("prompt", "Write.", input: "source", model: "primary", fallback: "backup"),
            .classify("classify", "Choose.", labels: ["yes", "no"], input: "source", model: "primary", fallback: "backup"),
            .template("template", "{{source}}", input: "source"),
            .agent("agent", "Answer.", tools: [tool], kits: ["shared"], input: "source", model: "primary", fallback: "backup"),
            .decide("decide", questions: [question], input: "source", model: "primary", fallback: "backup"),
            .request("request", request, input: "source"),
            .readImage("image", instruction: "Read.", input: "source", model: "primary", fallback: "backup"),
            .useTool("use", kit: "shared", tool: "lookup", arguments: ["query": "{{source}}"], input: "source"),
        ]
        let original: [Step] = [
            Step("prompt", .prompt(instruction: "Write."), input: "source", model: "primary", fallback: "backup"),
            Step("classify", .classify(instruction: "Choose.", labels: ["yes", "no"]), input: "source", model: "primary", fallback: "backup"),
            Step("template", .template("{{source}}"), input: "source"),
            Step("agent", .agent(instruction: "Answer.", tools: [tool], kits: ["shared"]), input: "source", model: "primary", fallback: "backup"),
            Step("decide", .decide(questions: [question]), input: "source", model: "primary", fallback: "backup"),
            Step("request", .request(request), input: "source"),
            Step("image", .readImage(instruction: "Read."), input: "source", model: "primary", fallback: "backup"),
            Step("use", .useTool(kit: "shared", tool: "lookup", arguments: ["query": "{{source}}"]), input: "source"),
        ]
        #expect(built == original)
        #expect(Step.readImage("ocr", model: .appleTextRecognition).kind == .readImage(instruction: ""))
        #expect(Step.agent("empty", "Answer.", model: "primary").kind == .agent(instruction: "Answer.", tools: [], kits: nil))
        #expect(Step.useTool("empty", kit: "shared", tool: "lookup").kind == .useTool(kit: "shared", tool: "lookup", arguments: [:]))
    }

    @Test func runtimeBranchBuildersPreserveTheExistingNodes() {
        let conditional = Step.ifEquals("route", reference: "label", value: "yes", input: "input") {
            Step.template("yes", "Yes")
        } otherwise: {
            Step.template("no", "No")
        }
        #expect(conditional == Step("route", .ifEquals(reference: "label", value: "yes",
                                                       then: [.template("yes", "Yes")], otherwise: [.template("no", "No")]), input: "input"))
        #expect(Step.ifEquals("empty", reference: "label", value: "yes") {}.kind ==
            .ifEquals(reference: "label", value: "yes", then: [], otherwise: []))
        let cases = [SwitchCase("yes") { Step.template("yes", "Yes") }, SwitchCase("empty") {}]
        let switched = Step.switchOn("switch", reference: "label", cases: cases, input: "input") {
            Step.template("no", "No")
        }
        #expect(switched == Step("switch", .switchOn(reference: "label", cases: cases, otherwise: [.template("no", "No")]), input: "input"))
        #expect(Step.switchOn("empty", reference: "label", cases: []).kind == .switchOn(reference: "label", cases: [], otherwise: []))
        #expect(cases.last == SwitchCase("empty", steps: []))
    }

    @Test func builtWorkflowRunsExtractionParallelAndRuntimeBranches() async throws {
        let extract = ScriptedModel("extract", replies: [#"{"merchant":"Coffee","total":8.3}"#])
        let tone = ScriptedModel("tone", replies: [#""positive""#])
        let executor = WorkflowExecutor(catalog: .scripted(["extract": extract, "tone": tone]))
        let workflow = Workflow("Receipt") {
            Step.extract("expense", instruction: "Extract the receipt.", model: "extract") {
                Field("merchant", .text)
                Field("total", .number)
            }
            Step.parallel("both", input: "input") {
                Step.classify("tone", "Tone?", labels: ["positive", "negative"], model: "tone")
                Step.template("amount", "{{expense.total}}")
            }
            Step.ifEquals("route", reference: "tone", value: "positive") {
                Step.template("yes", "{{expense.merchant}}: {{both.amount}}")
            } otherwise: {
                Step.template("no", "No")
            }
        }
        #expect(workflow.referenceIssues.isEmpty)
        let report = try await executor.run(workflow, input: .text("Coffee 8.30"))
        #expect(report.output == .text("Coffee: 8.3"))
        #expect(report.records.first { $0.step == "no" }?.skipped == true)
        #expect(extract.callCount == 1 && tone.callCount == 1)
    }

    @Test func builtSwitchRunsAtExecutionTimeAndOutputSelectionStillWorks() async throws {
        let workflow = Workflow(
            name: "Runtime switch",
            output: "route"
        ) {
            Step.switchOn("route", reference: "input", cases: [
                SwitchCase("yes") { Step.template("accepted", "Accepted") },
            ]) {
                Step.template("rejected", "Rejected")
            }
            Step.template("last", "Not the selected output")
        }
        let executor = WorkflowExecutor()
        #expect(try await executor.run(workflow, input: .text("yes")).output == .text("Accepted"))
        #expect(try await executor.run(workflow, input: .text("no")).output == .text("Rejected"))
    }

    @Test func reusingAnAgentConfigurationDoesNotShareItsConversation() async throws {
        let model = ScriptedModel("shared", replies: ["FIRST_RESULT_ONLY", "SECOND_RESULT_ONLY"])
        func assistant(_ name: String, _ instruction: String, input: String? = nil) -> Step {
            .agent(name, instruction, input: input, model: "shared")
        }
        let workflow = Workflow("Independent sessions") {
            assistant("first", "FIRST_INSTRUCTION_ONLY")
            assistant("second", "SECOND_INSTRUCTION_ONLY", input: "input")
        }
        let report = try await WorkflowExecutor(catalog: .scripted(["shared": model])).run(workflow, input: .text("ORIGINAL_INPUT"))
        #expect(report.output == .text("SECOND_RESULT_ONLY"))
        #expect(model.callCount == 2)
        #expect(model.prompts.count == 2)
        let second = try #require(model.prompts.last)
        #expect(second.contains("SECOND_INSTRUCTION_ONLY"))
        #expect(second.contains("ORIGINAL_INPUT"))
        #expect(!second.contains("FIRST_INSTRUCTION_ONLY"))
        #expect(!second.contains("FIRST_RESULT_ONLY"))
    }

    @Test func theNextAgentReceivesThePreviousResultAsDataNotConversationHistory() async throws {
        let model = ScriptedModel("shared", replies: ["FIRST_RESULT_ONLY", "SECOND_RESULT_ONLY"])
        let workflow = Workflow("Pass results") {
            Step.agent("first", "FIRST_INSTRUCTION_ONLY", model: "shared")
            Step.agent("second", "SECOND_INSTRUCTION_ONLY", model: "shared")
        }
        _ = try await WorkflowExecutor(catalog: .scripted(["shared": model])).run(workflow, input: .text("ORIGINAL_INPUT_ONLY"))
        let second = try #require(model.prompts.last)
        #expect(second.contains("FIRST_RESULT_ONLY"))
        #expect(!second.contains("FIRST_INSTRUCTION_ONLY"))
        #expect(!second.contains("ORIGINAL_INPUT_ONLY"))
    }
}
