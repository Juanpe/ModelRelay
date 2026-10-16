import Foundation
import Synchronization
import Testing
@testable import ModelRelay

@Suite struct CustomStepTests {
    @Test func compiledBodyReadsValuesAndFeedsLaterSteps() async throws {
        let workflow = Workflow("Normalize") {
            Step.template("prefix", "Hello")
            Step.custom("normalized", input: "input") { context in
                #expect(context.workflowInput == .text("  Ada  "))
                #expect(context["prefix"] == .text("Hello"))
                return .dictionary(["name": .text(context.input.textValue.trimmingCharacters(in: .whitespaces))])
            }
            Step.template("result", "{{prefix}}, {{normalized.name}}!")
        }
        let report = try await WorkflowExecutor().run(workflow, input: .text("  Ada  "))
        #expect(report.output == .text("Hello, Ada!"))
        #expect(report.records.map(\.step) == ["prefix", "normalized", "result"])
        #expect(report.records[1].input == "  Ada  ")
        #expect(report.records[1].model == nil)
    }

    @Test func previousValueIsTheDefaultInput() async throws {
        let workflow = Workflow("Count") {
            Step.template("text", "four")
            Step.custom("count") { .number(Double($0.input.textValue.count)) }
        }
        #expect(try await WorkflowExecutor().run(workflow, input: .null).output == .number(4))
    }

    @Test func bodiesRunOnlyAtExecutionTimeAndCopiesKeepIdentity() async throws {
        let calls = Mutex(0)
        let step = Step.custom("count") { _ in calls.withLock { $0 += 1 }; return .null }
        let copy = step
        #expect(step == copy)
        #expect(Set([step, copy]).count == 1)
        #expect(step != Step.custom("count") { _ in .null })
        #expect(calls.withLock { $0 } == 0)
        _ = try await WorkflowExecutor().run(Workflow("Run") { step }, input: .null)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func bodiesAreNotEncodedEvenInsideNestedBlocks() {
        let workflow = Workflow("Local only") {
            Step.parallel("parallel") { Step.custom("body") { $0.input } }
        }
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(workflow) }
    }

    @Test func jsonCannotConstructAnExecutableBody() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Step.Kind.self, from: Data(#"{"custom":{"_0":{}}}"#.utf8))
        }
    }

    @Test func serializableStepsStillRoundTrip() throws {
        let workflow = Workflow("Data") { Step.template("text", "{{input}}") }
        #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(workflow)) == workflow)
    }

    @Test func failureIsRecordedAndNeverRetriedOnFallback() async {
        struct Broken: Error {}
        let calls = Mutex(0)
        var step = Step.custom("broken") { _ in calls.withLock { $0 += 1 }; throw Broken() }
        step.fallback = "unused"
        let records = Mutex<[StepRecord]>([])
        await #expect(throws: RelayError.self) {
            try await WorkflowExecutor().run(Workflow("Fail") { step }, input: .text("data")) { record in
                records.withLock { $0.append(record) }
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(records.withLock { $0.first?.failure != nil && $0.first?.input == "data" })
    }

    @Test func timeoutCancelsCooperativeBody() async {
        let workflow = Workflow("Timeout") {
            Step.custom("slow") { _ in try await Task.sleep(for: .seconds(60)); return .null }
        }
        await #expect(throws: expectedOperationFailure(step: "slow", reason: "it ran longer than \(Duration.milliseconds(20))", category: .timeout, uncertain: true)) {
            try await WorkflowExecutor(stepTimeout: .milliseconds(20)).run(workflow, input: .null)
        }
    }

    @Test func cancellationPropagatesWithoutFailureWrapping() async {
        let started = Mutex(false)
        let workflow = Workflow("Cancel") {
            Step.custom("slow") { _ in started.withLock { $0 = true }; try await Task.sleep(for: .seconds(60)); return .null }
        }
        let task = Task { try await WorkflowExecutor().run(workflow, input: .null) }
        while !started.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func parallelBodiesSeeTheSameSnapshotNotTheirSiblings() async throws {
        let workflow = Workflow("Parallel") {
            Step.template("before", "ready")
            Step.parallel("both") {
                Step.custom("left") { context in
                    #expect(context["right"] == nil)
                    #expect(context["before"] == .text("ready"))
                    return .number(1)
                }
                Step.custom("right") { context in
                    #expect(context["left"] == nil)
                    #expect(context.input == .text("ready"))
                    return .number(2)
                }
            }
        }
        #expect(try await WorkflowExecutor().run(workflow, input: .null).output == .dictionary(["left": .number(1), "right": .number(2)]))
    }

    @Test func unselectedBranchDoesNotExecuteItsBody() async throws {
        let workflow = Workflow("Branch") {
            Step.ifEquals("route", reference: "input", value: "yes") {
                Step.custom("selected") { _ in .text("done") }
            } otherwise: {
                Step.custom("notSelected") { _ in Issue.record("Must not execute"); return .null }
            }
        }
        let report = try await WorkflowExecutor().run(workflow, input: .text("yes"))
        #expect(report.output == .text("done"))
        #expect(report.records.first(where: { $0.step == "notSelected" })?.skipped == true)
    }

    @Test func renamePreservesBodyAndUpdatesItsExplicitInput() {
        let body = Step.custom("custom", input: "source") { $0.input }
        var workflow = Workflow("Rename") { Step.template("source", "value"); body }
        let renamed = workflow.renameStep(from: "source", to: "renamed")
        #expect(renamed)
        #expect(workflow.steps[1].kind == body.kind)
        #expect(workflow.steps[1].input == "renamed")
        #expect(workflow.referenceIssues.isEmpty)
    }
}
