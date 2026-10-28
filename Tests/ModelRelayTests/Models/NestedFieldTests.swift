import AnyLanguageModel
import Foundation
import Testing
@testable import ModelRelay

@Suite struct NestedFieldTests {
    private let order: [Field] = [
        Field("table", .text),
        Field("lines", .list(.object([
            Field("kind", .choice(["add", "remove"])),
            Field("product", .text),
            Field("quantity", .number),
        ]))),
    ]

    @Test func extractReturnsListsOfObjects() async throws {
        let model: ScriptedModel = .init("small", replies: [#"""
        {"table": "4", "lines": [
            {"kind": "add", "product": "Beer", "quantity": 2},
            {"kind": "remove", "product": "Cola", "quantity": 1}
        ]}
        """#])
        let workflow: Workflow = .init(name: "Order", steps: [
            Step("order", .extract(instruction: "Read the order.", fields: order), model: "small"),
        ])

        let report: WorkflowExecutionReport = try await WorkflowExecutor(catalog: .scripted(["small": model]))
            .run(workflow, input: .text("Two beers, no cola"))

        #expect(report.output["table"] == .text("4"))
        #expect(report.output["lines"] == .list([
            .dictionary(["kind": .text("add"), "product": .text("Beer"), "quantity": .number(2)]),
            .dictionary(["kind": .text("remove"), "product": .text("Cola"), "quantity": .number(1)]),
        ]))
    }

    @Test func repeatedNamesKeepTheirOwnDefinitions() throws {
        let fields: [Field] = [
            Field("kind", .choice(["dine-in", "takeaway"])),
            Field("lines", .list(.object([Field("kind", .choice(["add", "remove"]))]))),
            Field("total", .object([Field("amount", .number)])),
        ]

        let schema: GenerationSchemaJSON = try .init(SchemaBuilder.object(named: "Result", fields: fields))

        #expect(Set(schema.definitions.keys) == ["Result", "kind", "linesItem", "kind2", "total"])
        #expect(schema.choices("kind") == ["dine-in", "takeaway"])
        #expect(schema.choices("kind2") == ["add", "remove"])
        let item: [String: Any]? = schema.definitions["linesItem"] as? [String: Any]
        #expect((item?["properties"] as? [String: Any])?["kind"] as? [String: String] == ["$ref": "#/$defs/kind2"])
    }

    @Test func emptyAndDuplicateNestedFieldsArePreflightIssues() async {
        let model: ScriptedModel = .init("small", replies: [])
        let executor: WorkflowExecutor = .init(catalog: .scripted(["small": model]))
        let workflow: Workflow = .init("Order") {
            Step.extract("order", instruction: "Read.", model: "small") {
                Field("empty", .object([]))
                Field("lines", .list(.object([Field("product", .text), Field("product", .number)])))
            }
        }

        let issues: [WorkflowValidationIssue] = await executor.validate(workflow)

        #expect(issues.count == 2)
        #expect(Set(issues.map(\.detail)) == ["objects need at least one field", "fields need unique nonempty names"])
        #expect(model.callCount == 0)
    }

    @Test func workflowsWithObjectsRoundTripAsJSON() throws {
        let workflow: Workflow = .init(name: "Order", steps: [
            Step("order", .extract(instruction: "Read.", fields: order), model: .appleOnDevice),
        ])

        let data: Data = try JSONEncoder().encode(workflow)

        #expect(try JSONDecoder().decode(Workflow.self, from: data) == workflow)
    }
}

/// A generation schema as the JSON providers receive, to read its shared definitions.
private struct GenerationSchemaJSON {
    let definitions: [String: Any]

    init(_ schema: GenerationSchema) throws {
        let json: Any = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        definitions = (json as? [String: Any])?["$defs"] as? [String: Any] ?? [:]
    }

    func choices(_ name: String) -> [String]? {
        (definitions[name] as? [String: Any])?["enum"] as? [String]
    }
}
