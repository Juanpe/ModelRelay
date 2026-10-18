import Foundation
import Testing
@testable import ModelRelay

struct WorkflowReferenceTests {
    @Test func siblingsAndParentsAreNotAvailableInsideBranches() async throws {
        let model = ScriptedModel("model", replies: [#""yes""#])
        let workflow = Workflow(name: "Paths", steps: [
            Step("label", .classify(instruction: "Choose", labels: ["yes", "no"]), model: "model"),
            Step("route", .switchOn(reference: "label", cases: [.init("yes", steps: [Step("yes", .template("YES"))])],
                                    otherwise: [Step("no", .template("NO"))])),
            Step("out", .template("{{route}}")),
        ])
        #expect(workflow.availableSteps(before: "yes").map(\.name) == ["label"])
        #expect(workflow.availableSteps(before: "no").map(\.name) == ["label"])
        #expect(workflow.availableSteps(before: "out").map(\.name) == ["label", "route"])
        #expect(workflow.referenceIssues.isEmpty)
        let report = try await WorkflowExecutor(catalog: .scripted(["model": model])).run(workflow, input: .text("Question"))
        #expect(report.output == .text("YES"))
    }

    @Test func parallelChildrenShareASnapshotAndExportTheirResults() async throws {
        let model = ScriptedModel("model", replies: ["A"])
        let workflow = Workflow(name: "Together", steps: [
            Step("both", .parallel([Step("a", .prompt(instruction: "Answer"), model: "model"), Step("b", .template("B"))])),
            Step("out", .template("{{a}} {{both.b}}")),
        ])
        #expect(workflow.availableSteps(before: "a").isEmpty)
        #expect(workflow.availableSteps(before: "b").isEmpty)
        #expect(workflow.availableSteps(before: "out").map(\.name) == ["a", "b", "both"])
        #expect(workflow.referenceIssues.isEmpty)
        let report = try await WorkflowExecutor(catalog: .scripted(["model": model])).run(workflow, input: .text("Question"))
        #expect(report.output == .text("A B"))
    }

    @Test func renamePreservesExecutionAndOnlyChangesReferenceTokens() async throws {
        let model = ScriptedModel("model", replies: [#"{"value":"hello"}"#])
        var workflow = Workflow(name: "Rename", steps: [
            Step("fields", .extract(instruction: "Extract", fields: [Field("value", .text)]), model: "model"),
            Step("out", .template("fields {{ fields.value }} {{input}}"), input: "fields.value"),
        ], output: "out")
        let renamed = workflow.renameStep(from: "fields", to: "receipt")
        #expect(renamed)
        #expect(workflow.steps[1].input == "receipt.value")
        #expect(workflow.steps[1].kind == .template("fields {{ receipt.value }} {{input}}"))
        #expect(workflow.referenceIssues.isEmpty)
        let report = try await WorkflowExecutor(catalog: .scripted(["model": model])).run(workflow, input: .text("input"))
        #expect(report.output == .text("fields hello input"))
        let reserved = workflow.renameStep(from: "receipt", to: "input")
        let duplicate = workflow.renameStep(from: "receipt", to: "out")
        #expect(!reserved)
        #expect(!duplicate)
    }

    @Test func renameUpdatesRequestsConditionsAndOutputWithoutChangingSecrets() {
        var workflow = Workflow(name: "Rename", steps: [
            Step("answer", .template("yes")),
            Step("route", .ifEquals(reference: "answer", value: "answer", then: [
                Step("request", .request(.init(.post, url: "https://api.test/{{answer}}",
                                               headers: [.init("Authorization", "{{secret.answer}}")], body: "{{answer}} {{answer2}}"))),
            ], otherwise: [])),
        ], output: "answer")
        let renamed = workflow.renameStep(from: "answer", to: "label")
        #expect(renamed)
        #expect(workflow.output == "label")
        guard case let .ifEquals(reference, literal, children, _) = workflow.steps[1].kind,
              case let .request(request) = children[0].kind else { Issue.record("Missing request"); return }
        #expect(reference == "label")
        #expect(literal == "answer")
        #expect(request.url == "https://api.test/{{label}}")
        #expect(request.headers[0].value == "{{secret.answer}}")
        #expect(request.body == "{{label}} {{answer2}}")
        #expect(workflow.referenceIssues.map(\.reference) == ["answer2"])
    }
}
