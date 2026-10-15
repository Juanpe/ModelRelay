import Foundation
import AnyLanguageModel
import ModelRelay
import ModelRelayMLX

// relay-bench: how well does a model do the small jobs ModelRelay is for?
// Usage: relay-bench [model-id]   (default: apple.on-device; MLX: mlx:qwen3-1.7b, mlx:gemma3-1b, …)

struct Receipt { let text: String; let merchant: String; let total: Double; let currency: String }
struct Message { let text: String; let label: String }

let receipts = [
    Receipt(text: "BLUE BOTTLE COFFEE\nFlat white 4.50\nCroissant 3.80\nTOTAL EUR 8.30\n12/10/2026", merchant: "Blue Bottle Coffee", total: 8.30, currency: "EUR"),
    Receipt(text: "Mercadona S.A.\nLeche 1,15\nPan 0,95\nManzanas 2,40\nTOTAL: 4,50 €\nTarjeta", merchant: "Mercadona", total: 4.50, currency: "EUR"),
    Receipt(text: "UBER\nTrip to SFO\nBase fare $31.20\nTolls $7.00\nTip $5.00\nTotal $43.20", merchant: "Uber", total: 43.20, currency: "USD"),
    Receipt(text: "THE IVY\nCHELSEA GARDEN\n2 x Burger  £37.00\nService 12.5% £4.63\nAMOUNT DUE £41.63", merchant: "The Ivy", total: 41.63, currency: "GBP"),
    Receipt(text: "Apple Store Online\nOrder W123\nUSB-C cable  25,00 €\nIVA incluido\nImporte total 25,00 EUR", merchant: "Apple Store", total: 25.00, currency: "EUR"),
]

let messages = [
    Message(text: "Production API is returning 500s for every request since 09:12.", label: "urgent"),
    Message(text: "Weekly newsletter: 10 new SwiftUI tips.", label: "later"),
    Message(text: "Your flight to Lisbon leaves in 2 hours, gate changed to B12.", label: "urgent"),
    Message(text: "Reminder: book club meets next month.", label: "later"),
]

let modelID = ModelID(CommandLine.arguments.dropFirst().first ?? ModelID.appleOnDevice.rawValue)
if modelID == .appleOnDevice, case .unavailable(let reason) = SystemLanguageModel.default.availability {
    print("Apple on-device model unavailable: \(reason)")
    exit(1)
}
var catalog = ModelCatalog()
#if MLX
catalog.registerMLXModels()
#endif
let runner = WorkflowRunner(catalog: catalog)

let extract = Workflow(name: "Receipt to expense", steps: [
    Step("expense", .extract(instruction: "Extract the expense from this receipt. total is the final amount paid.", fields: [
        Field("merchant", .text), Field("total", .number), Field("currency", .choice(["EUR", "USD", "GBP"])),
    ]), model: modelID),
])
let triage = Workflow(name: "Triage", steps: [
    Step("label", .classify(instruction: "Does this need attention today?", labels: ["urgent", "later"]), model: modelID),
])

// Warm up: the first call loads the model (and may download MLX weights);
// that time isn't answer latency, so it's excluded from the results.
print("Loading \(modelID)…")
_ = try? await WorkflowRunner(catalog: catalog, stepTimeout: .seconds(600))
    .run(triage, input: .text("Warm-up"))

func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

print("Model: \(modelID)\n")
print("Extract (merchant · total · currency)")
var extractScore = 0, extractTime: [Int] = []
for r in receipts {
    do {
        let report = try await runner.run(extract, input: .text(r.text))
        let o = report.output
        let merchant = o["merchant"]?.textValue.lowercased().contains(r.merchant.lowercased().prefix(6)) == true
        var total = false
        if case .number(let n)? = o["total"] { total = abs(n - r.total) < 0.005 }
        let currency = o["currency"]?.textValue == r.currency
        let score = [merchant, total, currency].filter { $0 }.count
        extractScore += score; extractTime.append(ms(report.duration))
        print(String(format: "  %@  %d/3  %5d ms  %@", score == 3 ? "✓" : "✗", score, ms(report.duration),
                     o.textValue.replacingOccurrences(of: "\n", with: " · ")))
    } catch { print("  ✗ error: \(error)") }
}
print("\nClassify (urgent · later)")
var classifyScore = 0, classifyTime: [Int] = []
for m in messages {
    do {
        let report = try await runner.run(triage, input: .text(m.text))
        let ok = report.output.textValue == m.label
        classifyScore += ok ? 1 : 0; classifyTime.append(ms(report.duration))
        print(String(format: "  %@  %5d ms  %@ → %@", ok ? "✓" : "✗", ms(report.duration), String(m.text.prefix(48)), report.output.textValue))
    } catch { print("  ✗ error: \(error)") }
}
func median(_ v: [Int]) -> Int { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
print("\nSummary")
print("  extract  \(extractScore)/\(receipts.count * 3) fields   median \(median(extractTime)) ms")
print("  classify \(classifyScore)/\(messages.count) labels   median \(median(classifyTime)) ms")
