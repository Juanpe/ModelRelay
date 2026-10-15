import Foundation
import ModelRelay

// The default path is deterministic: no model, network, credentials or UI.
// Pass --apple to opt into a real on-device model call instead.
let usesApple = CommandLine.arguments.contains("--apple")
let workflow = Workflow("Article summary", output: "result") {
    if usesApple {
        Step.prompt("summary", "Summarize the article in one sentence.", model: .appleOnDevice)
    } else {
        Step.template("summary", "Example summary of: {{input}}")
    }
    Step.parallel("format") {
        Step.template("message", "Summary: {{summary}}")
        Step.template("source", "Original: {{input}}")
    }
    Step.template("result", "{{format.message}}\n{{format.source}}")
}

guard workflow.referenceIssues.isEmpty else {
    fatalError("The example has invalid references: \(workflow.referenceIssues)")
}

let runner = WorkflowRunner()
let report = try await runner.run(workflow, input: .text("Small models can power focused workflows.")) { record in
    print("Finished \(record.step)")
}
print(report.output.textValue)

// The same workflow is a plain Codable value, independent of this executable.
let encoded = try JSONEncoder().encode(workflow)
let restored = try JSONDecoder().decode(Workflow.self, from: encoded)
precondition(restored == workflow)

// Developer-defined bodies need no interpreter or runner registration.
let local = Workflow("Custom Swift") {
    Step.custom("normalize") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
    Step.template("result", "Custom: {{normalize}}")
}
let customReport = try await runner.run(local, input: .text("  native Swift  "))
precondition(customReport.output == .text("Custom: NATIVE SWIFT"))
print(customReport.output.textValue)
do {
    _ = try JSONEncoder().encode(local)
    fatalError("A compiled closure must not be silently serialized")
} catch is EncodingError {
    print("Custom bodies stay in memory; declarative workflows still round-trip.")
}
