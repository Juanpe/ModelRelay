import AppKit
import ModelRelay
import ModelRelayMLX
import SwiftUI

/// A deliberately small form for trying ModelRelay: pick a sample workflow and a
/// model, type an input, run, and read what each step did.
@main
struct RelayPlaygroundApp: App {
    init() {
        // Launched from the command line, a SwiftPM executable needs to become
        // a regular app to show a window and take focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("ModelRelay Playground") {
            PlaygroundView()
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

struct Sample: Identifiable, Hashable, Sendable {
    let id: String
    let input: String
    let make: @Sendable (ModelID, ModelID?) -> Workflow

    static func == (lhs: Sample, rhs: Sample) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [Sample] = [
        Sample(id: "Receipt to expense",
               input: "BLUE BOTTLE COFFEE\nFlat white 4.50\nCroissant 3.80\nTOTAL EUR 8.30\n12/10/2026") { model, fallback in
            Workflow(name: "Receipt to expense", steps: [
                Step("expense", .extract(instruction: "Extract the expense from this receipt. total is the final amount paid.", fields: [
                    Field("merchant", .text), Field("total", .number), Field("currency", .choice(["EUR", "USD", "GBP"])),
                    Field("date", .text, description: "ISO 8601 date"),
                ]), model: model, fallback: fallback),
            ])
        },
        Sample(id: "Triage a message",
               input: "Your flight to Lisbon leaves in 2 hours, gate changed to B12.") { model, fallback in
            Workflow(name: "Triage", steps: [
                Step("label", .classify(instruction: "Does this need attention today?", labels: ["urgent", "later"]),
                     model: model, fallback: fallback),
                Step("route", .ifEquals(reference: "label", value: "urgent",
                    then: [Step("reply", .prompt(instruction: "Write a one-sentence acknowledgement for this message."),
                                input: "input", model: model, fallback: fallback)],
                    otherwise: [Step("note", .template("Saved for later: {{input}}"))])),
            ])
        },
        Sample(id: "Summary and tone",
               input: "The launch went better than expected: 3,000 sign-ups on day one, two crash reports, both fixed.") { model, fallback in
            Workflow(name: "Summary and tone", steps: [
                Step("both", .parallel([
                    Step("summary", .prompt(instruction: "Summarize in one short sentence."), model: model, fallback: fallback),
                    Step("tone", .classify(instruction: "What is the tone?", labels: ["positive", "neutral", "negative"]),
                         model: model, fallback: fallback),
                ])),
                Step("card", .template("{{summary}} — {{tone}}")),
            ])
        },
    ]
}

@MainActor
@Observable
final class PlaygroundModel {
    enum Phase { case idle, running, done(RunReport), failed(String) }

    var sample = Sample.all[0] { didSet { input = sample.input } }
    var input = Sample.all[0].input
    var model: ModelID = .appleOnDevice
    var fallback: ModelID?
    var phase = Phase.idle
    private var task: Task<Void, Never>?

    let models: [ModelID] = {
        var ids: [ModelID] = [.appleOnDevice, .applePrivateCloud]
        #if MLX
        ids += MLXModels.ids.sorted { $0.rawValue < $1.rawValue }
        #endif
        return ids
    }()
    private let runner: WorkflowRunner = {
        var catalog = ModelCatalog()
        #if MLX
        // MLX weights download from Hugging Face the first time a model runs.
        catalog.registerMLXModels()
        #endif
        return WorkflowRunner(catalog: catalog)
    }()

    func run() {
        task?.cancel()
        phase = .running
        let workflow = sample.make(model, fallback)
        let input = Value.text(input)
        task = Task {
            do {
                let report = try await runner.run(workflow, input: input)
                guard !Task.isCancelled else { return }
                phase = .done(report)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(String(describing: error))
            }
        }
    }
}

struct PlaygroundView: View {
    @State private var model = PlaygroundModel()

    var body: some View {
        HSplitView {
            Form {
                Section("Workflow") {
                    Picker("Sample", selection: $model.sample) {
                        ForEach(Sample.all) { Text($0.id).tag($0) }
                    }
                    Picker("Model", selection: $model.model) {
                        ForEach(model.models, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Fallback", selection: $model.fallback) {
                        Text("None").tag(ModelID?.none)
                        ForEach(model.models, id: \.self) { Text($0.rawValue).tag(ModelID?.some($0)) }
                    }
                }
                Section("Input") {
                    TextEditor(text: $model.input)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                }
                Button {
                    model.run()
                } label: {
                    Label("Run", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.input.isEmpty)
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, idealWidth: 360)

            ResultView(phase: model.phase)
                .frame(minWidth: 380)
        }
    }
}

struct ResultView: View {
    let phase: PlaygroundModel.Phase

    var body: some View {
        switch phase {
        case .idle:
            ContentUnavailableView("Run a workflow", systemImage: "arrow.triangle.branch",
                                   description: Text("Pick a sample and a model, then press Run (⌘↩)."))
        case .running:
            ProgressView("Running…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("The run failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message).font(.callout.monospaced()))
        case .done(let report):
            List {
                Section("Output · \(report.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))") {
                    Text(report.output.textValue)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Section("Steps") {
                    ForEach(Array(report.records.enumerated()), id: \.offset) { _, record in
                        StepRow(record: record)
                    }
                }
            }
        }
    }
}

struct StepRow: View {
    let record: StepRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: record.skipped ? "arrow.turn.down.right" : "checkmark.circle.fill")
                    .foregroundStyle(record.skipped ? Color.secondary : Color.green)
                Text(record.step).bold()
                Spacer()
                if let model = record.model {
                    Text(record.usedFallback ? "\(model.rawValue) (fallback)" : model.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(record.usedFallback ? Color.orange : Color.secondary)
                }
                Text(record.skipped ? "skipped" : record.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !record.skipped {
                Text(record.value.textValue)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
