import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

private func text(of transcript: Transcript) -> String {
    transcript.map { entry in
        let segments: [Transcript.Segment]
        switch entry {
        case .prompt(let value): segments = value.segments
        case .response(let value): segments = value.segments
        case .toolOutput(let value): segments = value.segments
        default: segments = []
        }
        return segments.compactMap { segment in
            switch segment {
            case .text(let value): value.content
            case .structure(let value): value.content.jsonString
            default: nil
            }
        }.joined()
    }.joined(separator: "\n")
}

private actor ConversationLoadGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite struct ConversationTests {
    @Test func sameConversationUsesOneNativeSessionAndEarlierResponses() async throws {
        let model = ScriptedModel("shared", replies: ["FIRST_REPLY", "SECOND_REPLY"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("shared") { loads.withLock { $0 += 1 }; return model }
        let workflow = Workflow("Continue") {
            Step.agent("first", "FIRST_TASK", model: "shared").withContext(.conversation("writer"))
            Step.agent("second", "SECOND_TASK", input: "input", model: "shared").withContext(.conversation("writer"))
        }
        let report = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .text("ORIGINAL"))
        #expect(report.output == .text("SECOND_REPLY"))
        #expect(loads.withLock { $0 } == 1)
        #expect(model.sessionIDs.count == 2)
        #expect(model.sessionIDs.first == model.sessionIDs.last)
        #expect(text(of: model.histories[1]).contains("FIRST_TASK"))
        #expect(text(of: model.histories[1]).contains("FIRST_REPLY"))
        #expect(report.records.allSatisfy { $0.conversation == "writer" })
    }

    @Test func sharedBackendDoesNotImplicitlyShareHistory() async throws {
        let model = ScriptedModel("shared", replies: ["FIRST_REPLY", "SECOND_REPLY"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("shared") { loads.withLock { $0 += 1 }; return model }
        let workflow = Workflow("Isolate") {
            Step.prompt("first", "FIRST_TASK", model: "shared")
            Step.prompt("second", "SECOND_TASK", input: "input", model: "shared")
        }
        _ = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .text("INPUT"))
        #expect(loads.withLock { $0 } == 1)
        #expect(!text(of: model.histories[1]).contains("FIRST_TASK"))
        #expect(!text(of: model.histories[1]).contains("FIRST_REPLY"))
    }

    @Test func handoffCopiesSelectedFieldsNotPreviousInputOrHistory() async throws {
        let first = ScriptedModel("first", replies: [#"{"title":"SHARED","private":"HIDDEN"}"#])
        let second = ScriptedModel("second", replies: ["Reviewed"])
        let workflow = Workflow("Handoff") {
            Step.extract("draft", instruction: "HIDDEN_INSTRUCTION", model: "first") {
                Field("title", .text); Field("private", .text)
            }.withContext(.conversation("author"))
            Step.template("unrelated", "UNRELATED_PREVIOUS")
            Step.prompt("review", "Review selected data.", model: "second").withContext(.handoff(["draft.title"]))
        }
        _ = try await WorkflowExecutor(catalog: .scripted(["first": first, "second": second]))
            .run(workflow, input: .text("ORIGINAL_PRIVATE_INPUT"))
        let seen = try #require(second.prompts.first)
        #expect(seen.contains("SHARED"))
        #expect(!seen.contains("HIDDEN"))
        #expect(!seen.contains("UNRELATED_PREVIOUS"))
        #expect(!seen.contains("ORIGINAL_PRIVATE_INPUT"))
    }

    @Test func conversationNamesAreScopedToTheirModel() async throws {
        let a = ScriptedModel("a", replies: ["A_REPLY"])
        let b = ScriptedModel("b", replies: ["B_REPLY"])
        let workflow = Workflow("No provider replay") {
            Step.prompt("a", "A_PRIVATE_TASK", model: "a").withContext(.conversation("same"))
            Step.prompt("b", "B_TASK", input: "input", model: "b").withContext(.conversation("same"))
        }
        _ = try await WorkflowExecutor(catalog: .scripted(["a": a, "b": b])).run(workflow, input: .text("PUBLIC"))
        #expect(!text(of: b.histories[0]).contains("A_PRIVATE_TASK"))
        #expect(!text(of: b.histories[0]).contains("A_REPLY"))
    }

    @Test func separateRunsNeverShareConversationOrFactoryCache() async throws {
        let model = ScriptedModel("shared", replies: ["ONE", "TWO"])
        let loads = Mutex(0)
        let executor = WorkflowExecutor(catalog: ModelCatalog().registering("shared") { loads.withLock { $0 += 1 }; return model })
        let workflow = Workflow("Run-local") {
            Step.prompt("answer", "Answer.", model: "shared").withContext(.conversation("same"))
        }
        _ = try await executor.run(workflow, input: .text("FIRST_RUN_PRIVATE"))
        _ = try await executor.run(workflow, input: .text("SECOND_RUN"))
        #expect(loads.withLock { $0 } == 2)
        #expect(!text(of: model.histories[1]).contains("FIRST_RUN_PRIVATE"))
        #expect(!text(of: model.histories[1]).contains("ONE"))
    }

    @Test func parallelModelLoadsAreCoalescedWithSeparateConversations() async throws {
        let model = ScriptedModel("shared", replies: ["ONE", "TWO"])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("shared") {
            loads.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(20))
            return model
        }
        let workflow = Workflow("Parallel") {
            Step.parallel("both") {
                Step.prompt("a", "A_TASK", model: "shared").withContext(.conversation("a"))
                Step.prompt("b", "B_TASK", model: "shared").withContext(.conversation("b"))
            }
        }
        _ = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null)
        #expect(loads.withLock { $0 } == 1)
        #expect(model.histories.allSatisfy { history in
            let seen = text(of: history)
            return !(seen.contains("A_TASK") && seen.contains("B_TASK"))
        })
    }

    @Test func ambiguousParallelSharingIsRejectedBeforeAnyBodyOrModelRuns() async {
        let calls = Mutex(0)
        let workflow = Workflow("Invalid") {
            Step.custom("before") { _ in calls.withLock { $0 += 1 }; return .null }
            Step.parallel("parallel") {
                Step.prompt("a", "A", model: "model").withContext(.conversation("same"))
                Step.ifEquals("route", reference: "input", value: "yes") {
                    Step.prompt("b", "B", model: "model").withContext(.conversation("same"))
                }
            }
        }
        await #expect(throws: RelayError.invalidContext(step: "parallel", reason: "parallel branches must not share a conversation for the same model")) {
            try await WorkflowExecutor().run(workflow, input: .null)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func handoffCannotAlsoUseAnImplicitlyConflictingExplicitInput() async {
        let workflow = Workflow("Invalid") {
            Step.prompt("answer", "A", input: "input", model: "model").withContext(.handoff([]))
        }
        await #expect(throws: RelayError.invalidContext(step: "answer", reason: "handoff replaces input; do not also set input")) {
            try await WorkflowExecutor().run(workflow, input: .null)
        }
    }

    @Test func handoffMissingValuesFailAndRenameTracksFieldReferences() async throws {
        var workflow = Workflow("References") {
            Step.template("source", "a")
            Step.prompt("answer", "A", model: "model").withContext(.handoff(["source.name", "missing"]))
        }
        #expect(workflow.referenceIssues.contains(.init(step: "answer", reference: "missing")))
        let renamed = workflow.renameStep(from: "source", to: "renamed")
        #expect(renamed)
        #expect(workflow.steps[1].context == .handoff(["renamed.name", "missing"]))
        let issues = await WorkflowExecutor().validate(workflow)
        #expect(issues.contains { $0.kind == .unavailableReference && $0.detail == "missing" })
        await #expect(throws: WorkflowValidationError.self) {
            try await WorkflowExecutor().run(workflow, input: .null)
        }
    }

    @Test func nativeToolsAreReboundForEachConversationStep() async throws {
        let model = ScriptedModel("shared", replies: [#"<tool:lookup>{}"#, "ONE", #"<tool:lookup>{}"#, "TWO"])
        let server = FakeServer(json: "{}")
        let first = AgentTool(name: "lookup", description: "Look up.", request: HTTPRequest(url: "https://example.test/first"))
        let second = AgentTool(name: "lookup", description: "Look up.", request: HTTPRequest(url: "https://example.test/second"))
        let workflow = Workflow("Rebind") {
            Step.agent("a", "FIRST", tools: [first], model: "model").withContext(.conversation("same"))
            Step.agent("b", "SECOND", tools: [second], model: "model").withContext(.conversation("same"))
        }
        let report = try await WorkflowExecutor(catalog: .scripted(["model": model]), requests: server).run(workflow, input: .null)
        #expect(server.requests.map(\.url.path) == ["/first", "/second"])
        #expect(report.records.map(\.toolCalls) == [["lookup"], ["lookup"]])
    }

    @Test func conversationSchemaCanChangeBetweenTextAndExtraction() async throws {
        let model = ScriptedModel("shared", replies: ["REMEMBER_ME", #"{"count":2}"#])
        let workflow = Workflow("Schemas") {
            Step.prompt("first", "Remember.", model: "model").withContext(.conversation("same"))
            Step.extract("second", instruction: "Count.", model: "model") { Field("count", .number) }
                .withContext(.conversation("same"))
        }
        let report = try await WorkflowExecutor(catalog: .scripted(["model": model])).run(workflow, input: .null)
        #expect(report.output["count"] == .number(2))
        #expect(model.sessionIDs.first == model.sessionIDs.last)
    }

    @Test func contextAndPolicyRoundTripAndOldStepsDecode() throws {
        let workflow = Workflow("Data") {
            Step.prompt("answer", "A", model: "model").withContext(.conversation("same")).withPolicy(.localOnly)
        }
        #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(workflow)) == workflow)
        let old = try JSONDecoder().decode(Step.self, from: Data(#"{"name":"old","kind":{"template":{"_0":"text"}}}"#.utf8))
        #expect(old.context == nil)
        #expect(old.policy == nil)
    }

    @Test func cancellationDuringFactoryLoadingCancelsTheLoad() async {
        let started = Mutex(false)
        let catalog = ModelCatalog().registering("slow") {
            started.withLock { $0 = true }
            try await Task.sleep(for: .seconds(60))
            return ScriptedModel("never", replies: [])
        }
        let workflow = Workflow("Cancel") { Step.prompt("answer", "A", model: "slow") }
        let task = Task { try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null) }
        while !started.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func failedTurnsRollBackAndFallbackNeverReplaysAnotherModelsHistory() async throws {
        let primary = ScriptedModel("primary", replies: ["ORIGINAL_REPLY", nil, "FINAL_REPLY"])
        let fallback = ScriptedModel("fallback", replies: ["FALLBACK_REPLY"])
        let workflow = Workflow("Rollback") {
            Step.prompt("first", "ORIGINAL_TASK", model: "primary").withContext(.conversation("same"))
            Step.prompt("second", "FAILED_TASK", input: "input", model: "primary", fallback: "fallback")
                .withContext(.conversation("same"))
            Step.prompt("last", "FINAL_TASK", input: "input", model: "primary").withContext(.conversation("same"))
        }
        let report = try await WorkflowExecutor(catalog: .scripted(["primary": primary, "fallback": fallback]))
            .run(workflow, input: .text("INPUT"))
        #expect(report.records[1].usedFallback)
        #expect(!text(of: fallback.histories[0]).contains("ORIGINAL_TASK"))
        #expect(text(of: primary.histories[2]).contains("ORIGINAL_REPLY"))
        #expect(!text(of: primary.histories[2]).contains("FAILED_TASK"))
        #expect(!text(of: primary.histories[2]).contains("FALLBACK_REPLY"))
    }

    @Test(arguments: ["", "missing"])
    func invalidHandoffReferencesFailWithoutCrashing(_ reference: String) async {
        let workflow = Workflow("Bad reference") {
            Step.prompt("answer", "A", model: "model").withContext(.handoff([reference]))
        }
        let issues = await WorkflowExecutor().validate(workflow)
        #expect(issues.contains { $0.kind == .unavailableReference && $0.detail == reference })
        await #expect(throws: WorkflowValidationError.self) {
            try await WorkflowExecutor().run(workflow, input: .null)
        }
    }

    @Test func cancellingOneSharedLoadWaiterDoesNotCancelTheOther() async throws {
        let resource = SharedResource<Int>()
        let loads = Mutex(0)
        let gate = ConversationLoadGate()
        let load: @Sendable () async throws -> Int = {
            loads.withLock { $0 += 1 }
            await gate.wait()
            return 42
        }
        let first = Task { try await resource.get(load) }
        let second = Task { try await resource.get(load) }
        while await resource.waiterCount < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await gate.open()
        #expect(try await second.value == 42)
        #expect(loads.withLock { $0 } == 1)
        #expect(try await resource.get { 99 } == 42)
        await resource.finish()
    }
}
