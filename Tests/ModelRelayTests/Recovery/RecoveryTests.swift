import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

@Suite struct RecoveryTests {
    @Test func executionIdentityIsDistinctFromDefinitionAndStableAcrossResume() async throws {
        let workflow = Workflow("Reusable definition") {
            Step.template("gate", "approved").requiringApproval("Review")
        }
        let store = MemoryCheckpoints()
        let executor = WorkflowExecutor()
        let first = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        let data = try JSONEncoder().encode(first)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["executionID"] as? String)?.uppercased() == first.executionID.uuidString)
        #expect(json["runID"] == nil)
        #expect(first.workflowID == workflow.id)

        let restored = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: data)
        _ = try completed(await executor.resume(workflow, from: restored, revision: "1", approval: .approve, store: store))
        let confirmed = try await store.latest()
        #expect(confirmed.executionID == first.executionID)
        #expect(confirmed.workflowID == workflow.id)
        let second = try paused(await executor.start(workflow, input: .null, revision: "1", store: store))
        #expect(second.executionID != first.executionID)
        #expect(second.workflowID == first.workflowID)
    }

    @Test func previousCheckpointIdentityKeyIsNotSilentlyAccepted() async throws {
        let workflow = Workflow("No legacy alias") { Step.template("gate", "ok").requiringApproval("Review") }
        let store = MemoryCheckpoints()
        let checkpoint = try paused(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        json["runID"] = json.removeValue(forKey: "executionID")
        let previous = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: previous) }
    }

    @Test func recreatedCustomBodiesResumeWithoutSerializingOrRepeatingCode() async throws {
        let id = UUID()
        let before = Mutex(0)
        let after = Mutex(0)
        func workflow() -> Workflow {
            Workflow("Compile in the app", id: id) {
                Step.custom("first") { context in before.withLock { $0 += 1 }; return .text(context.input.textValue + " one") }
                Step.custom("second") { context in after.withLock { $0 += 1 }; return .text(context["first"]!.textValue + " two") }
                    .requiringApproval("Review the draft")
            }
        }
        let store = MemoryCheckpoints()
        let first = workflow()
        let gate = try paused(await WorkflowExecutor().start(first, input: .text("start"), revision: "v1", store: store))
        #expect(gate.step == "second")
        #expect(gate.approval == "Review the draft")
        #expect(before.withLock { $0 } == 1)
        #expect(after.withLock { $0 } == 0)
        #expect(gate.input == .text("start"))
        #expect(gate.results["first"] == .text("start one"))
        #expect(gate.records.map(\.step) == ["first"])
        #expect(throws: (any Error).self) { try JSONEncoder().encode(first) }
        let report = try completed(await WorkflowExecutor().resume(workflow(), from: gate, revision: "v1", approval: .approve, store: store))
        #expect(report.output == .text("start one two"))
        #expect(report.records.map(\.step) == ["first", "second"])
        #expect(before.withLock { $0 } == 1)
        #expect(after.withLock { $0 } == 1)
        let saves = await store.saves
        #expect(saves.map(\.generation) == Array(0 ..< saves.count))
        #expect(saves.last?.status == .completed)
    }

    @Test func emptyWorkflowAndNamedOutputSurviveCompletedResume() async throws {
        let empty = Workflow("Empty") {}
        let emptyStore = MemoryCheckpoints()
        let report = try completed(await WorkflowExecutor().start(empty, input: .text("input"), revision: "1", store: emptyStore))
        #expect(report.output == .text("input"))
        let workflow = Workflow("Selected", output: "first") {
            Step.template("first", "private").withPolicy(.localOnly)
            Step.template("last", "public", input: "input")
        }
        let store = MemoryCheckpoints()
        let initial = try completed(await WorkflowExecutor().start(workflow, input: .null, revision: "1", store: store))
        let checkpoint = try await store.latest()
        let restored = try completed(await WorkflowExecutor().resume(workflow, from: checkpoint, revision: "1", store: store))
        #expect(restored.output == .text("private"))
        #expect(restored.outputDataAccess == .localOnly)
        #expect(restored.records == initial.records)
        #expect(restored.duration == initial.duration)
    }
}
