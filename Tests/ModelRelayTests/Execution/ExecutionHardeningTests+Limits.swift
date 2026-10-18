import Foundation
import Synchronization
import Testing
@testable import ModelRelay

extension ExecutionHardeningTests {
    @Test func modelLimitStopsFallbackBeforeLoadingIt() async {
        let primary = ScriptedModel("primary", replies: [nil])
        let fallback = ScriptedModel("fallback", replies: ["unused"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("primary") { primary }.registering("fallback") { loads.withLock { $0 += 1 }; return fallback }
        let workflow = Workflow("Limited fallback") { Step.prompt("ask", "Q", model: "primary", fallback: "fallback") }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog, limits: .init(maxModelCalls: 1)).run(workflow, input: .null)
        }
        #expect(primary.callCount == 1)
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func zeroModelBudgetNeverLoadsAFactory() async {
        let loads = Mutex(0)
        let model = ScriptedModel("model", replies: ["unused"])
        let catalog = ModelCatalog().registering("model") { loads.withLock { $0 += 1 }; return model }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await WorkflowExecutor(catalog: catalog).run(
                Workflow("Zero") { Step.prompt("ask", "Q", model: "model") },
                input: .null,
                limits: .init(maxModelCalls: 0)
            )
        }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func toolLimitCoversDirectRequestsAndNativeAgentCallsTogether() async {
        let model = ScriptedModel("model", replies: [#"<tool:lookup>{}"#, "unused"])
        let server = FakeServer(json: "{}")
        let tool = AgentTool(name: "lookup", description: "Look up", request: HTTPRequest(url: "https://example.test/tool"))
        let workflow = Workflow("Tools") {
            Step.request("first", HTTPRequest(url: "https://example.test/direct"))
            Step.agent("second", "Find", tools: [tool], model: "model")
        }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(catalog: .scripted(["model": model]), requests: server)
                .run(workflow, input: .null, limits: .init(maxToolCalls: 1))
        }
        #expect(server.requests.count == 1)
    }

    @Test func parallelBranchesShareAnAtomicToolBudget() async {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("Parallel tools") {
            Step.parallel("both") {
                for index in 0 ..< 12 {
                    Step.request("call\(index)", HTTPRequest(url: "https://example.test/\(index)"))
                }
            }
        }
        await #expect(throws: RelayError.limitExceeded(.toolCalls)) {
            try await WorkflowExecutor(requests: server).run(workflow, input: .null, limits: .init(maxToolCalls: 3))
        }
        #expect(server.requests.count <= 3)
    }

    @Test func nestedParallelBlocksRespectLeafConcurrencyWithoutDeadlock() async throws {
        let probe = ConcurrencyProbe()
        let workflow = Workflow("Nested concurrency") {
            Step.parallel("outer") {
                for branch in 0 ..< 3 {
                    Step.parallel("branch\(branch)") {
                        for index in 0 ..< 3 {
                            Step.custom("leaf\(branch)_\(index)") { _ in try await probe.work() }
                        }
                    }
                }
            }
        }
        _ = try await WorkflowExecutor().run(workflow, input: .null, limits: .init(maxDuration: .seconds(2), maxConcurrentSteps: 2))
        #expect(await probe.peak == 2)
        #expect(await probe.finished == 9)
    }

    @Test func totalDeadlineCancelsAnInflightNativeModelWithoutFallback() async {
        let primary = ScriptedModel("primary", replies: ["<hang>"])
        let fallback = ScriptedModel("fallback", replies: ["unused"])
        let events = Mutex<[WorkflowExecutionEvent]>([])
        let workflow = Workflow("Deadline") { Step.prompt("ask", "Q", model: "primary", fallback: "fallback") }
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor(catalog: .scripted(["primary": primary, "fallback": fallback]))
                .execute(workflow, input: .null, limits: .init(maxDuration: .milliseconds(40)))
                .observing(onEvent: { event in events.withLock { $0.append(event) } })
        }
        #expect(fallback.callCount == 0)
        #expect(events.withLock { $0.contains { $0.kind == .limitReached && $0.limit == .duration } })
        #expect(events.withLock { $0.last?.kind } == .executionFailed)
    }

    @Test func durationBudgetIncludesCustomBodiesAndCancelsQueuedLeaves() async {
        let workflow = Workflow("Queued work") {
            Step.parallel("block") {
                for index in 0 ..< 20 {
                    Step.custom("slow\(index)") { _ in try await Task.sleep(for: .seconds(1)); return .null }
                }
            }
        }
        await #expect(throws: RelayError.limitExceeded(.duration)) {
            try await WorkflowExecutor().run(workflow, input: .null, limits: .init(maxDuration: .milliseconds(25), maxConcurrentSteps: 1))
        }
    }

    @Test func executorLimitsCannotBeRelaxedAndCountersAreNotSharedAcrossRuns() async throws {
        let model = ScriptedModel("model", replies: ["one", "two", "three", "must not run"])
        let executor = WorkflowExecutor(catalog: .scripted(["model": model]), limits: .init(maxModelCalls: 1))
        let workflow = Workflow("One") { Step.prompt("ask", "Q", model: "model") }
        let first = try await executor.run(workflow, input: .null, limits: .init(maxModelCalls: 100))
        let second = try await executor.run(workflow, input: .null)
        #expect(first.usage.modelCalls == 1 && second.usage.modelCalls == 1)
        #expect(first.executionID != second.executionID)
        let twice = Workflow("Two") {
            Step.prompt("first", "Q", model: "model")
            Step.prompt("second", "Q", model: "model")
        }
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await executor.run(twice, input: .null, limits: .init(maxModelCalls: 100))
        }
        #expect(model.callCount == 3)
    }

    @Test func invalidLimitsFailBeforeWork() async {
        let calls = Mutex(0)
        let workflow = Workflow("Invalid limits") { Step.custom("body") { _ in calls.withLock { $0 += 1 }; return .null } }
        for limits in [WorkflowExecutionLimits(maxModelCalls: -1), .init(maxToolCalls: -1), .init(maxConcurrentSteps: 0), .init(maxDuration: .seconds(-1))] {
            await #expect(throws: RelayError.invalidLimits) { try await WorkflowExecutor(limits: limits).run(workflow, input: .null) }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func decisionModelsUseTheSameGlobalModelBudget() async {
        let model = CountedDecisions()
        let workflow = Workflow("Decisions") {
            Step.decide("first", questions: [Question("yes", "Yes?", .yesNo)], model: "decision")
            Step.decide("second", questions: [Question("yes", "Yes?", .yesNo)], model: "decision")
        }
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering(decisions: "decision") { model })
        await #expect(throws: RelayError.limitExceeded(.modelCalls)) {
            try await executor.run(workflow, input: .null, limits: .init(maxModelCalls: 1))
        }
        #expect(model.calls == 1)
    }
}
