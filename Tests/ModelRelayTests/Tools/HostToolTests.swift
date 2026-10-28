import Foundation
import Synchronization
import Testing
@testable import ModelRelay

/// An order the host app owns; its tools change it in place.
private final class Order: Sendable {
    private let state: Mutex<[String: Value]> = .init([:])
    var lines: [String: Value] { state.withLock { $0 } }

    func kit(onAdd: @escaping @Sendable () -> Void = {}) -> HostToolKit {
        HostToolKit(id: "order", name: "Order", tools: [
            HostTool(name: "add_line", description: "Adds a product to the order.", parameters: [
                Field("product", .text),
                Field("quantity", .number),
                Field("extras", .list(.object([Field("name", .text), Field("quantity", .number)]))),
            ]) { arguments in
                onAdd()
                let product: String = arguments["product"]?.textValue ?? ""
                self.state.withLock { $0[product] = .dictionary(arguments) }
                return .text("Added \(product)")
            },
            HostTool(
                name: "find_product",
                description: "Finds a product on the menu.",
                parameters: [Field("query", .text)],
                changesSomething: false
            ) { arguments in
                .dictionary(["id": .text("p-1"), "name": .text(arguments["query"]?.textValue ?? "")])
            },
        ])
    }
}

private final class Approvals: Sendable {
    private let seen: Mutex<[String]> = .init([])
    var requests: [String] { seen.withLock { $0 } }

    func policy(_ answer: Bool) -> WritePolicy {
        .ask { request in
            self.seen.withLock { $0.append(request.description) }
            return answer
        }
    }
}

@Suite struct HostToolTests {
    private let agent: Workflow = .init(name: "Order", steps: [
        Step("answer", .agent(instruction: "Update the order.", tools: [], kits: ["order"]), model: "small"),
    ])

    @Test func agentsCallHostToolsAndWritesAskFirst() async throws {
        let order: Order = .init()
        let approvals: Approvals = .init()
        let model: ScriptedModel = .init("small", replies: [
            #"<tool:add_line>{"product": "Beer", "quantity": 2, "extras": [{"name": "Lemon", "quantity": 1}]}"#, "Added.",
        ])
        let executor: WorkflowExecutor = .init(catalog: .scripted(["small": model]), writePolicy: approvals.policy(true), hostToolKits: [order.kit()])

        let report: WorkflowExecutionReport = try await executor.run(agent, input: .text("Two beers with lemon"))

        #expect(report.output == .text("Added."))
        #expect(report.records.first?.toolCalls == ["add_line"])
        #expect(order.lines["Beer"]?["extras"] == .list([.dictionary(["name": .text("Lemon"), "quantity": .number(1)])]))
        let request: String = try #require(approvals.requests.first)
        #expect(request.hasPrefix("POST host:order"))
        #expect(request.contains(#""tool" : "add_line""#))
        #expect(model.prompts.last?.contains("[add_line] \"Added Beer\"") == true)
    }

    @Test func deniedWritesNeverRunTheBody() async {
        let order: Order = .init()
        let runs: Mutex<Int> = .init(0)
        let model: ScriptedModel = .init("small", replies: [#"<tool:add_line>{"product": "Beer", "quantity": 1, "extras": []}"#, "Done."])
        let executor: WorkflowExecutor = .init(catalog: .scripted(["small": model]), hostToolKits: [order.kit { runs.withLock { $0 += 1 } }])

        await #expect(throws: (any Error).self) {
            try await executor.run(agent, input: .text("A beer"))
        }

        #expect(runs.withLock { $0 } == 0)
        #expect(order.lines.isEmpty)
    }

    @Test func readOnlyExecutionsOfferOnlyReadOnlyHostTools() async throws {
        let model: ScriptedModel = .init("small", replies: ["Nothing to change."])
        let executor: WorkflowExecutor = .init(catalog: .scripted(["small": model]), hostToolKits: [Order().kit()], policy: .readOnly)

        _ = try await executor.run(agent, input: .text("Is there beer?"))

        #expect(model.visibleTools == [["find_product"]])
    }

    @Test func localOnlyExecutionsMayCallHostTools() async throws {
        let model: ScriptedModel = .init("small", replies: [#"<tool:find_product>{"query": "Beer"}"#, "Found it."])
        let catalog: ModelCatalog = .init().registering("small", location: .local) { model }
        let executor: WorkflowExecutor = .init(catalog: catalog, hostToolKits: [Order().kit()], policy: .localOnly)

        let report: WorkflowExecutionReport = try await executor.run(agent, input: .text("Is there beer?"))

        #expect(report.records.first?.toolCalls == ["find_product"])
        #expect(report.output == .text("Found it."))
    }

    @Test func useAToolCallsHostToolsWithTypedArguments() async throws {
        let order: Order = .init()
        let workflow: Workflow = .init(name: "Order", steps: [
            Step("add", .useTool(kit: "order", tool: "add_line", arguments: ["product": "{{input}}", "quantity": "3", "extras": "[]"])),
        ])
        let executor: WorkflowExecutor = .init(writePolicy: .allow, hostToolKits: [order.kit()])

        let report: WorkflowExecutionReport = try await executor.run(workflow, input: .text("Cola"))

        #expect(report.output == .text("Added Cola"))
        #expect(order.lines["Cola"] == .dictionary(["product": .text("Cola"), "quantity": .number(3), "extras": .list([])]))
    }

    @Test func missingAmbiguousAndInvalidHostToolsArePreflightIssues() async {
        let invalid: HostToolKit = .init(id: "menu", name: "Menu", tools: [
            HostTool(name: "pick", description: "Picks.", parameters: [Field("size", .choice([]))]) { _ in .null },
        ])
        let executor: WorkflowExecutor = .init(
            toolKits: [ToolKit(id: "order", name: "Order API", tools: [])],
            hostToolKits: [Order().kit(), invalid]
        )
        let workflow: Workflow = .init(name: "Order", steps: [
            Step("both", .useTool(kit: "order", tool: "add_line", arguments: [:])),
            Step("missing", .useTool(kit: "menu", tool: "remove_line", arguments: [:])),
            Step("pick", .useTool(kit: "menu", tool: "pick", arguments: [:])),
        ])

        let issues: [WorkflowValidationIssue] = await executor.validate(workflow)

        #expect(issues == [
            .init(step: "both", kind: .unavailableTool, detail: "order names both a tool kit and a host tool kit"),
            .init(step: "missing", kind: .unavailableTool, detail: "remove_line"),
            .init(step: "pick", kind: .invalidSchema, detail: "choices must be nonempty and unique"),
        ])
    }

    @Test func hostToolKitsLeaveRecoveryDefinitionsAsTheyWere() async throws {
        let kits: [ToolKit] = [ToolKit(id: "api", name: "API", tools: [])]
        let workflow: Workflow = .init(name: "Order", steps: [Step("note", .template("{{input}}"))])

        let without: String = try await WorkflowExecutor(toolKits: kits).recoveryDefinition(workflow, revision: "1")
        let with: String = try await WorkflowExecutor(toolKits: kits, hostToolKits: [Order().kit()]).recoveryDefinition(workflow, revision: "1")

        #expect(with == without)
    }
}
