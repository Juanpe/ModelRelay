import AnyLanguageModel
import Foundation
import Testing
@testable import ModelRelay

private final class CompatibilityTool: Tool {
    typealias Arguments = GeneratedContent
    let name = "lookup"
    let description = "Look up a value."
    let value: String
    var parameters: GenerationSchema { try! SchemaBuilder.object(named: "Arguments", fields: []) }
    init(_ value: String) { self.value = value }
    func call(arguments: GeneratedContent) async throws -> String { value }
}

@Suite struct PlatformCompatibilityTests {
    @Test func builtInModelIDsRemainRegisteredOnEverySupportedOS() {
        let ids = Set(ModelCatalog().ids)
        #expect(ids.isSuperset(of: [.appleOnDevice, .applePrivateCloud, .appleTextRecognition]))
    }

    @Test(arguments: [ModelID.appleOnDevice, .applePrivateCloud])
    func unsupportedAppleModelsFailClearlyAndCanUseAConfiguredFallback(id: ModelID) async throws {
        let version: Int
        if id == .appleOnDevice {
            if #available(macOS 26, iOS 26, visionOS 26, *) { return }
            version = 26
        } else {
            if #available(macOS 27, iOS 27, visionOS 27, *) { return }
            version = 27
        }
        let catalog = ModelCatalog()
        do {
            _ = try await catalog.model(id)
            Issue.record("expected an unsupported OS error")
        } catch {
            #expect(failureCategory(error) == .modelUnavailable)
            #expect(failureReason(error).contains("requires iOS \(version)"))
        }
        let backup = ScriptedModel("backup", replies: ["ok"])
        let workflow = Workflow(name: "Compatible fallback") {
            Step.prompt("answer", "Reply", model: id, fallback: "backup")
        }
        let executor = WorkflowExecutor(catalog: catalog.registering("backup") { backup })
        #expect(await executor.validate(workflow).isEmpty)
        let report = try await executor.run(workflow, input: .null)
        #expect(report.output == .text("ok"))
        #expect(report.records.first?.usedFallback == true)
        #expect(report.usage.modelCalls == 2)
        #expect(backup.callCount == 1)
    }

    @Test func nonAppleProvidersKeepDynamicSessionsOnOlderSystems() async throws {
        let resources = ExecutionResources()
        let model = ScriptedModel("model", replies: [])
        let conversation = try await resources.acquire(
            nil,
            model: "model",
            backend: model,
            tools: [],
            data: .unrestricted,
            step: "first"
        )
        #expect(conversation.tools != nil)
        await resources.release(nil, model: "model", conversation: conversation)
        await resources.finish()
    }

    @Test func appleProviderUsesFixedToolsBeforeOS27() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let resources = ExecutionResources()
        let conversation = try await resources.acquire(
            nil,
            model: .appleOnDevice,
            backend: SystemLanguageModel.default,
            tools: [],
            data: .unrestricted,
            step: "first"
        )
        if #available(macOS 27, iOS 27, visionOS 27, *) {
            #expect(conversation.tools != nil)
        } else {
            #expect(conversation.tools == nil)
        }
        await resources.release(nil, model: .appleOnDevice, conversation: conversation)
        await resources.finish()
    }

    @Test func fixedSessionsKeepHistoryAndUseOnlyTheCurrentStepsTools() async throws {
        let resources = ExecutionResources(dynamicInstructions: false)
        let model = ScriptedModel("model", replies: [#"<tool:lookup>{}"#, "EARLIER_REPLY", #"<tool:lookup>{}"#, "LATER_REPLY"])
        let context = StepContext.conversation("writer")
        let first = try await resources.acquire(
            context,
            model: "model",
            backend: model,
            tools: [CompatibilityTool("OLD_RESULT")],
            data: .localOnly,
            step: "first"
        )
        #expect(first.tools == nil)
        #expect(try await first.session.streamResponse(to: "FIRST_TASK").collect().content == "EARLIER_REPLY")
        await first.session.waitForResponseCompletion()
        await resources.release(context, model: "model", conversation: first)

        let second = try await resources.acquire(
            context,
            model: "model",
            backend: model,
            tools: [CompatibilityTool("NEW_RESULT")],
            data: .localOnly,
            step: "second"
        )
        #expect(first.session !== second.session)
        #expect(try await second.session.streamResponse(to: "SECOND_TASK").collect().content == "LATER_REPLY")
        await second.session.waitForResponseCompletion()
        await resources.release(context, model: "model", conversation: second)
        #expect(model.prompts.last?.contains("FIRST_TASK") == true)
        let history = String(decoding: try JSONEncoder().encode(#require(model.histories.last)), as: UTF8.self)
        #expect(history.contains("EARLIER_REPLY"))
        #expect(model.prompts.last?.contains("OLD_RESULT") == true)
        #expect(model.prompts.last?.contains("NEW_RESULT") == true)
        #expect(await resources.historyPolicy(context, models: ["model"]) == .localOnly)
        let saved = await resources.snapshot()
        #expect(saved.count == 1)
        #expect(saved.first?.data == .localOnly)
        await resources.finish()

        let restored = ExecutionResources(conversations: try JSONDecoder().decode(
            [CheckpointConversation].self,
            from: JSONEncoder().encode(saved)
        ), dynamicInstructions: false)
        let continuedModel = ScriptedModel("restored", replies: ["THIRD"])
        let third = try await restored.acquire(
            context,
            model: "model",
            backend: continuedModel,
            tools: [],
            data: .localOnly,
            step: "third"
        )
        #expect(third.session.tools.isEmpty)
        #expect(try await third.session.respond(to: "THIRD_TASK").content == "THIRD")
        #expect(continuedModel.prompts.first?.contains("SECOND_TASK") == true)
        #expect(continuedModel.prompts.first?.contains("NEW_RESULT") == true)
        await restored.release(context, model: "model", conversation: third)
        await restored.finish()
    }

    @Test func fixedSessionsDiscardFailedPromptsBeforeContinuing() async throws {
        let resources = ExecutionResources(dynamicInstructions: false)
        let model = ScriptedModel("model", replies: ["FIRST_REPLY", nil, "THIRD_REPLY"])
        let context = StepContext.conversation("writer")
        for (index, prompt) in ["FIRST_TASK", "FAILED_TASK", "THIRD_TASK"].enumerated() {
            let conversation = try await resources.acquire(
                context,
                model: "model",
                backend: model,
                tools: [],
                data: .unrestricted,
                step: "step\(index)"
            )
            if index == 1 {
                await #expect(throws: ScriptedModel.Failure.self) { try await conversation.session.respond(to: prompt) }
            } else {
                _ = try await conversation.session.respond(to: prompt)
            }
            await conversation.session.waitForResponseCompletion()
            await resources.release(context, model: "model", conversation: conversation)
        }
        let history = String(decoding: try JSONEncoder().encode(#require(model.histories.last)), as: UTF8.self)
        #expect(history.contains("FIRST_REPLY"))
        #expect(!history.contains("FAILED_TASK"))
        await resources.finish()
    }

    @Test func fixedConversationStorageDoesNotRetainToolWrappers() async throws {
        let resources = ExecutionResources(dynamicInstructions: false)
        let model = ScriptedModel("model", replies: ["ok"])
        let context = StepContext.conversation("writer")
        var tool: CompatibilityTool? = CompatibilityTool("value")
        weak let released = tool
        do {
            let conversation = try await resources.acquire(
                context,
                model: "model",
                backend: model,
                tools: [try #require(tool)],
                data: .unrestricted,
                step: "first"
            )
            _ = try await conversation.session.respond(to: "Task")
            await conversation.session.waitForResponseCompletion()
            await resources.release(context, model: "model", conversation: conversation)
        }
        tool = nil
        #expect(released == nil)
        #expect(await resources.snapshot().count == 1)
        await resources.finish()
    }
}
