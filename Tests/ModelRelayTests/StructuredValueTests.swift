import Foundation
import Testing
@testable import ModelRelay

@Suite struct StructuredValueTests {
    private let expense = FakeServer(json: #"{"merchant": "Blue Bottle", "total": 8.3, "items": [{"name": "Latte", "price": 4.5}]}"#)

    @Test func modelsReadFieldsAndListsAsJSON() async throws {
        let model = ScriptedModel("small", replies: ["Coffee.", "Coffee again."])
        let runner = WorkflowRunner(catalog: .scripted(["small": model]), requests: expense)
        let workflow = Workflow(name: "Receipt", steps: [
            Step("expense", .request(HTTPRequest(url: "https://api.example.com/expense"))),
            Step("kind", .prompt(instruction: "What kind of expense is it?"), model: "small"),
            Step("again", .prompt(instruction: "Is {{expense}} a meal?"), model: "small"),
            Step("note", .template("{{expense}}")),
        ])
        let report = try await runner.run(workflow, input: .text(""))
        let asked = try #require(model.prompts.first)
        #expect(asked.contains(#""merchant" : "Blue Bottle""#))
        #expect(asked.contains(#""price" : 4.5"#))
        #expect(model.prompts.last?.contains(#""total" : 8.3"#) == true)
        // People still read text.
        #expect(report.output.textValue.contains("merchant: Blue Bottle"))
    }

    @Test func plainTextReachesModelsAsWritten() async throws {
        let model = ScriptedModel("small", replies: ["Hi."])
        let workflow = Workflow(name: "Hi", steps: [Step("hi", .prompt(instruction: "Answer."), model: "small")])
        _ = try await WorkflowRunner(catalog: .scripted(["small": model])).run(workflow, input: .text("Hello there"))
        #expect(model.prompts.first == "Answer.\n\nInput:\nHello there")
    }

    @Test func jsonBodiesInsertWholeValuesAsJSON() async throws {
        let api = FakeServer(json: "{}")
        let workflow = Workflow(name: "Send", steps: [
            Step.custom("expense") { _ in .dictionary([
                "merchant": .text(#"Blue "Bottle""#), "total": .number(4.5 + 3.8), "ok": .bool(true),
                "items": .list([.text("Latte"), .text("Croissant")]), "code": .text("08"),
            ]) },
            Step("send", .request(HTTPRequest(.post, url: "https://api.example.com/expenses", body: """
                {"expense": {{expense}}, "items": {{expense.items}}, "total": {{expense.total}}, "approved": {{expense.ok}},
                 "note": "Paid {{expense.total}} at {{expense.merchant}}", "who": {{expense.merchant}},
                 "code": {{expense.code}}, "chat": {{secret.CHAT}}, "missing": {{nothing}}}
                """))),
        ])
        let runner = WorkflowRunner(requests: api, secrets: FakeSecrets(values: ["CHAT": "123456"]),
                                    writePolicy: .allow)
        _ = try await runner.run(workflow, input: .text(""))
        let body = try #require(api.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["expense"] as? [String: Any])?["merchant"] as? String == #"Blue "Bottle""#)
        #expect(json["items"] as? [String] == ["Latte", "Croissant"])
        #expect(json["total"] as? Double == 8.3)
        #expect(json["approved"] as? Bool == true)
        #expect(json["note"] as? String == #"Paid 8.3 at Blue "Bottle""#)
        #expect(json["who"] as? String == #"Blue "Bottle""#)
        #expect(json["code"] as? String == "08")
        #expect(json["chat"] as? Int == 123456)
        #expect(json["missing"] is NSNull)
        #expect(String(decoding: body, as: UTF8.self).contains(#""total": 8.3,"#))
    }
}
