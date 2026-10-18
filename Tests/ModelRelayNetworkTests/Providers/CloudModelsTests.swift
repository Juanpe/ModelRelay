import Foundation
import ModelRelay
import ModelRelayCloud
import Synchronization
import Testing

private struct PresetDecisionModel: DecisionModel {
    func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
        questions.map { Answer(name: $0.name, result: .yesNo(true)) }
    }
}

@Suite struct CloudModelsTests {
    @Test func predefinedIDsAreDiscoverableAndPreserveTheirSerializedName() throws {
        #expect(CloudModels.ids == [CloudModels.jev])
        #expect(CloudModels.jev.rawValue == "jev")
        #expect(!ModelCatalog().ids.contains(CloudModels.jev))

        let encoded: Data = try JSONEncoder().encode(CloudModels.jev)
        #expect(String(bytes: encoded, encoding: .utf8) == #""jev""#)
        #expect(try JSONDecoder().decode(ModelID.self, from: encoded) == CloudModels.jev)
    }

    @Test(arguments: [CloudModels.jev, ModelID("custom-decision")])
    func predefinedAndCustomIDsUseTheExistingLazyRegistration(id: ModelID) async throws {
        let loads: Mutex<Int> = .init(0)
        var catalog: ModelCatalog = .init()
        catalog.register(decisions: id, location: .remote) {
            loads.withLock { $0 += 1 }
            return PresetDecisionModel()
        }
        let workflow: Workflow = .init(name: "Built-in decision") {
            Step.decide("result", questions: [Question("urgent", "Is it urgent?", .yesNo)], model: id)
        }
        let executor: WorkflowExecutor = .init(catalog: catalog)

        #expect(await executor.validate(workflow).isEmpty)
        #expect(loads.withLock { $0 } == 0)

        let report: WorkflowExecutionReport = try await executor.run(workflow, input: .text("Please respond today"))
        #expect(report.output["urgent"] == .bool(true))
        #expect(report.records.first?.model == id)
        #expect(loads.withLock { $0 } == 1)
    }
}
