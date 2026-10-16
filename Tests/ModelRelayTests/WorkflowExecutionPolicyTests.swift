import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

private func policyFailure(_ operation: () async throws -> WorkflowExecutionReport) async {
    do { _ = try await operation(); Issue.record("Expected a policy violation") }
    catch RelayError.policyViolation { }
    catch { Issue.record("Unexpected error: \(error)") }
}

private final class PolicyServer: ToolServerConnector, ToolServerConnection {
    let connects = Mutex(0)
    let calls = Mutex(0)
    func connect(to kit: ToolKit) async throws -> any ToolServerConnection {
        connects.withLock { $0 += 1 }; return self
    }
    func tools() async throws -> [ServerTool] {
        [.init(name: "read", description: "Read.", changesSomething: false),
         .init(name: "write", description: "Write.", changesSomething: true)]
    }
    func call(_ tool: String, arguments: [String: Value]) async throws -> Value {
        calls.withLock { $0 += 1 }; return .text("done")
    }
}

@Suite struct WorkflowExecutionPolicyTests {
    @Test(arguments: [ModelLocation.remote, .unspecified])
    func localOnlyRejectsNonlocalModelsBeforeTheirFactoriesRun(_ location: ModelLocation) async {
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("provider", location: location) {
            loads.withLock { $0 += 1 }; return ScriptedModel("never", replies: [])
        }
        let workflow = Workflow("Private") { Step.prompt("answer", "A", model: "provider") }
        await policyFailure { try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .text("PRIVATE")) }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func declaredLocalModelWorksAndReportsPrivacy() async throws {
        let model = ScriptedModel("local", replies: ["answer"])
        let catalog = ModelCatalog().registering("local", location: .local) { model }
        let workflow = Workflow("Private") { Step.prompt("answer", "A", model: "local") }
        let report = try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .text("PRIVATE"))
        #expect(report.output == .text("answer"))
        #expect(report.outputDataAccess == .localOnly)
        #expect(report.records.first?.dataAccess == .localOnly)
    }

    @Test func localFailureCannotSendDataToARemoteFallback() async {
        let local = ScriptedModel("local", replies: [nil])
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering("local", location: .local) { local }
            .registering("cloud", location: .remote) { loads.withLock { $0 += 1 }; return ScriptedModel("cloud", replies: []) }
        let workflow = Workflow("Private fallback") { Step.prompt("answer", "A", model: "local", fallback: "cloud") }
        await policyFailure { try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .text("PRIVATE")) }
        #expect(local.callCount == 1)
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func localOnlyRejectsHTTPBeforeSecretsOrTransport() async {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("No network") {
            Step.request("read", HTTPRequest(url: "https://example.test/?key={{secret.KEY}}"))
        }
        await policyFailure {
            try await WorkflowExecutor(requests: server, policy: .localOnly).run(workflow, input: .null)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func privateValuesStayPrivateThroughTemplatesAndFieldReferences() async {
        let cloud = ScriptedModel("cloud", replies: [])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let workflow = Workflow("Taint") {
            Step.custom("private") { _ in .dictionary(["name": .text("PRIVATE")]) }.withPolicy(.localOnly)
            Step.template("copy", "{{private.name}}")
            Step.prompt("send", "Use {{copy}}", input: "input", model: "cloud")
        }
        await policyFailure { try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null) }
        #expect(cloud.callCount == 0)
    }

    @Test func handoffDoesNotDeclassifyPrivateValues() async {
        let cloud = ScriptedModel("cloud", replies: [])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let workflow = Workflow("Handoff") {
            Step.custom("private") { _ in .text("PRIVATE") }.withPolicy(.localOnly)
            Step.template("public", "Public", input: "input")
            Step.prompt("send", "Use selected data.", model: "cloud").withContext(.handoff(["private"]))
        }
        await policyFailure { try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null) }
        #expect(cloud.callCount == 0)
    }

    @Test func parallelMergePreservesPrivateDataButPublicSiblingCanBeSelected() async throws {
        let cloud = ScriptedModel("cloud", replies: ["Reviewed"])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let workflow = Workflow("Select public") {
            Step.parallel("both") {
                Step.custom("private") { _ in .text("PRIVATE") }.withPolicy(.localOnly)
                Step.template("public", "PUBLIC")
            }
            Step.prompt("review", "Review.", model: "cloud").withContext(.handoff(["public"]))
        }
        let report = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null)
        #expect(report.output == .text("Reviewed"))
        #expect(report.outputDataAccess == .unrestricted)
        #expect(!cloud.prompts[0].contains("PRIVATE"))
        var merged = workflow
        merged.steps[1].context = .handoff(["both"])
        await policyFailure { try await WorkflowExecutor(catalog: catalog).run(merged, input: .null) }
        #expect(cloud.callCount == 1)
    }

    @Test func conditionalControlFlowCarriesTheConditionPrivacy() async {
        let cloud = ScriptedModel("cloud", replies: [])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let workflow = Workflow("Private branch") {
            Step.custom("decision") { _ in .text("yes") }.withPolicy(.localOnly)
            Step.ifEquals("branch", reference: "decision", value: "yes", input: "input") {
                Step.template("selected", "Chosen", input: "input")
            }
            Step.prompt("send", "Send.", model: "cloud").withContext(.handoff(["branch"]))
        }
        await policyFailure { try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null) }
        #expect(cloud.callCount == 0)
    }

    @Test func customOutputsAreConservativelyRestrictedByAllAccessibleValues() async {
        let cloud = ScriptedModel("cloud", replies: [])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let workflow = Workflow("Custom context") {
            Step.template("private", "PRIVATE").withPolicy(.localOnly)
            Step.custom("copy", input: "input") { $0["private"] ?? .null }
            Step.prompt("send", "Send.", model: "cloud").withContext(.handoff(["copy"]))
        }
        await policyFailure { try await WorkflowExecutor(catalog: catalog).run(workflow, input: .null) }
        #expect(cloud.callCount == 0)
    }

    @Test func aChildCannotRelaxItsParentAndApprovalCannotOverrideReadOnly() async {
        let server = FakeServer(json: "{}")
        let approvals = Mutex(0)
        let workflow = Workflow("Read only") {
            Step.parallel("block") {
                Step.request("write", HTTPRequest(.post, url: "https://example.test")).withPolicy(.unrestricted)
            }.withPolicy(.readOnly)
        }
        await policyFailure {
            try await WorkflowExecutor(requests: server, writePolicy: .ask { _ in approvals.withLock { $0 += 1 }; return true })
                .run(workflow, input: .null)
        }
        #expect(server.requests.isEmpty)
        #expect(approvals.withLock { $0 } == 0)
    }

    @Test func perStepReadOnlyDoesNotRestrictAnUnrelatedLaterApprovedWrite() async throws {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("Approval") {
            Step.request("read", HTTPRequest(url: "https://example.test")).withPolicy(.readOnly)
            Step.request("write", HTTPRequest(.post, url: "https://example.test"))
        }
        _ = try await WorkflowExecutor(requests: server, writePolicy: .allow).run(workflow, input: .null)
        #expect(server.requests.map(\.method) == [.get, .post])
    }

    @Test func readonlyAgentOnlySeesReadTools() async throws {
        let model = ScriptedModel("model", replies: [#"<tool:read>{}"#, "done"])
        let server = FakeServer(json: "{}")
        let read = AgentTool(name: "read", description: "Read", request: HTTPRequest(url: "https://example.test"))
        let write = AgentTool(name: "write", description: "Write", request: HTTPRequest(.post, url: "https://example.test"))
        let workflow = Workflow("Readonly") {
            Step.agent("answer", "Read.", tools: [read, write], model: "model").withPolicy(.readOnly)
        }
        _ = try await WorkflowExecutor(catalog: .scripted(["model": model]), requests: server, writePolicy: .allow)
            .run(workflow, input: .null)
        #expect(server.requests.count == 1)
        let definitions = model.visibleTools.flatMap { $0 }
        #expect(definitions.contains("read"))
        #expect(!definitions.contains("write"))
    }

    @Test func noToolsAgentDoesNotConnectOrAdvertiseTools() async throws {
        let model = ScriptedModel("model", replies: ["done"])
        let server = PolicyServer()
        let kit = ToolKit(id: "remote", name: "Remote", tools: [], server: ToolServer(url: "https://mcp.test"))
        let workflow = Workflow("No tools") { Step.agent("answer", "Answer.", kits: ["remote"], model: "model") }
        _ = try await WorkflowExecutor(catalog: .scripted(["model": model]), toolKits: [kit], toolServers: server, policy: .noTools)
            .run(workflow, input: .null)
        #expect(server.connects.withLock { $0 } == 0)
        #expect(server.calls.withLock { $0 } == 0)
    }

    @Test func localOnlyMCPNeverConnectsEvenForReadTools() async {
        let server = PolicyServer()
        let kit = ToolKit(id: "remote", name: "Remote", tools: [], server: ToolServer(url: "https://mcp.test"))
        let workflow = Workflow("No network") { Step.useTool("read", kit: "remote", tool: "read") }
        await policyFailure {
            try await WorkflowExecutor(toolKits: [kit], toolServers: server, policy: .localOnly).run(workflow, input: .null)
        }
        #expect(server.connects.withLock { $0 } == 0)
    }

    @Test func readOnlyMCPRejectsWritesAfterDiscoveryButBeforeCall() async {
        let server = PolicyServer()
        let kit = ToolKit(id: "remote", name: "Remote", tools: [], server: ToolServer(url: "https://mcp.test"))
        let workflow = Workflow("Read only") { Step.useTool("write", kit: "remote", tool: "write") }
        await policyFailure {
            try await WorkflowExecutor(writePolicy: .allow, toolKits: [kit], toolServers: server, policy: .readOnly).run(workflow, input: .null)
        }
        #expect(server.connects.withLock { $0 } == 1)
        #expect(server.calls.withLock { $0 } == 0)
    }

    @Test func conversationHistoryPreservesPrivacyAndDropsPreviousStepTools() async throws {
        let model = ScriptedModel("local", replies: ["PRIVATE_REPLY", "done"])
        let catalog = ModelCatalog().registering("local", location: .local) { model }
        let server = FakeServer(json: "{}")
        let tool = AgentTool(name: "network", description: "Network", request: HTTPRequest(url: "https://example.test"))
        let workflow = Workflow("Remember privacy") {
            Step.prompt("private", "Remember.", model: "local").withContext(.conversation("same")).withPolicy(.localOnly)
            Step.agent("second", "Answer.", tools: [tool], input: "input", model: "local").withContext(.conversation("same"))
        }
        let report = try await WorkflowExecutor(catalog: catalog, requests: server).run(workflow, input: .null)
        #expect(server.requests.isEmpty)
        #expect(report.outputDataAccess == .localOnly)
        #expect(report.records.last?.dataAccess == .localOnly)
    }

    @Test func privacyAlsoChecksDecisionModelsBeforeFactoryExecution() async {
        struct NeverDecide: DecisionModel {
            func decide(_ questions: [Question], about input: String) async throws -> [Answer] { Issue.record("Must not run"); return [] }
        }
        let loads = Mutex(0)
        let catalog = ModelCatalog().registering(decisions: "jev", location: .remote) { loads.withLock { $0 += 1 }; return NeverDecide() }
        let workflow = Workflow("Decide") { Step.decide("answer", questions: [Question("x", "Is it?", .yesNo)], model: "jev") }
        await policyFailure { try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .null) }
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func declaringAnotherFactoryForAnIDDoesNotRetainOldLocalTrust() async {
        let model = ScriptedModel("model", replies: [])
        var catalog = ModelCatalog().registering("model", location: .local) { model }
        catalog.register("model") { model }
        let workflow = Workflow("Reset trust") { Step.prompt("answer", "A", model: "model") }
        await policyFailure { try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .null) }
        #expect(model.callCount == 0)
    }

    @Test func localToolSetTemplatesCannotBypassValuePrivacy() async {
        let server = FakeServer(json: "{}")
        let tool = AgentTool(name: "send", description: "Send", request: HTTPRequest(.post, url: "https://example.test", body: "{{private}}"))
        let kit = ToolKit(id: "kit", name: "Kit", tools: [tool])
        let workflow = Workflow("Kit templates") {
            Step.template("private", "PRIVATE").withPolicy(.localOnly)
            Step.useTool("send", kit: "kit", tool: "send", input: "input")
        }
        await policyFailure {
            try await WorkflowExecutor(requests: server, writePolicy: .allow, toolKits: [kit]).run(workflow, input: .null)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func anOldToolWrapperCannotBeCalledAfterItsStepEnded() async {
        let server = FakeServer(json: "{}")
        let log = ToolCallLog(limit: 6)
        let spec = AgentTool(name: "write", description: "Write", request: HTTPRequest(.post, url: "https://example.test"))
        let tool = RequestTool(spec: spec, step: "old", context: RequestContext(requests: server, secrets: nil, writePolicy: .allow,
            timeout: .seconds(1)), log: log, resolve: { _ in nil })
        log.finish()
        await #expect(throws: InvalidOutput.self) { try await tool.call(arguments: AnyLanguageModel.GeneratedContent(json: "{}")) }
        #expect(server.requests.isEmpty)
    }

    @Test func runPoliciesCanNarrowOneRunWithoutLeakingIntoAnother() async throws {
        let cloud = ScriptedModel("cloud", replies: ["PUBLIC_REPLY"])
        let catalog = ModelCatalog().registering("cloud", location: .remote) { cloud }
        let executor = WorkflowExecutor(catalog: catalog)
        let workflow = Workflow("Per-run data") { Step.prompt("answer", "Answer.", model: "cloud") }
        await policyFailure { try await executor.run(workflow, input: .text("PRIVATE"), policy: .localOnly) }
        let report = try await executor.run(workflow, input: .text("PUBLIC"))
        #expect(report.output == .text("PUBLIC_REPLY"))
        #expect(cloud.callCount == 1)
        #expect(!cloud.prompts[0].contains("PRIVATE"))
        await policyFailure {
            try await WorkflowExecutor(catalog: catalog, policy: .localOnly).run(workflow, input: .text("PRIVATE"), policy: .unrestricted)
        }
        #expect(cloud.callCount == 1)
    }

    @Test func explicitWorkflowOutputReportsItsOwnLabelNotTheLastStepsLabel() async throws {
        let workflow = Workflow("Selected output", output: "private") {
            Step.template("private", "PRIVATE").withPolicy(.localOnly)
            Step.template("public", "PUBLIC", input: "input")
        }
        let report = try await WorkflowExecutor().run(workflow, input: .null)
        #expect(report.output == .text("PRIVATE"))
        #expect(report.outputDataAccess == .localOnly)
        #expect(report.records.last?.dataAccess == .unrestricted)
    }

    @Test func noToolsAlsoRejectsADirectReadRequest() async {
        let server = FakeServer(json: "{}")
        let workflow = Workflow("No requests") { Step.request("read", HTTPRequest(url: "https://example.test")) }
        await policyFailure { try await WorkflowExecutor(requests: server, policy: .noTools).run(workflow, input: .null) }
        #expect(server.requests.isEmpty)
    }

    @Test func chainedPolicyModifiersComposeInsteadOfRemovingRestrictions() {
        let step = Step.template("private", "PRIVATE")
            .withPolicy(.localOnly).withPolicy(.readOnly).withPolicy(.unrestricted)
        #expect(step.policy == WorkflowExecutionPolicy(data: .localOnly, tools: .readOnly))
        #expect(step.withPolicy(.noTools).policy == WorkflowExecutionPolicy(data: .localOnly, tools: .denied))
    }
}
