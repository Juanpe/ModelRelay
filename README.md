# ModelRelay

Chain small language-model steps — prompt, extract, classify, branch, run in
parallel — and let every step use the smallest model that does the job.

ModelRelay is built on Apple's FoundationModels (iOS, macOS and visionOS 27).
Any FoundationModels `LanguageModel` can run a step: Apple's on-device model,
Private Cloud Compute, MLX models (`ModelRelayMLX`, through `MLXFoundationModels`), or your own.

```swift
import ModelRelay

let workflow = Workflow(name: "Receipt to expense", steps: [
    Step("expense", .extract(instruction: "Extract the expense from this receipt.", fields: [
        Field("merchant", .text),
        Field("total", .number),
        Field("currency", .choice(["EUR", "USD", "GBP"])),
    ]), model: .appleOnDevice, fallback: "mlx:qwen3-1.7b"),
])

let report = try await WorkflowRunner().run(workflow, input: .text(receiptText))
report.output["total"]   // .number(8.3)
```

## Concepts

- **Workflow**: steps that run top to bottom. `ifEquals` and `parallel` are
  blocks that contain steps, so a workflow is a small tree, never a free graph.
- **Step**: `prompt` (text), `extract` (typed fields, guided generation),
  `classify` (one label), `template` (`{{step.field}}` substitution, no model).
- **Values**: typed (`text`, `number`, `bool`, `list`, `dictionary`), so results
  are easy to hand to Shortcuts or any caller.
- **Models**: a `ModelCatalog` maps a `ModelID` to a `LanguageModel`. Apple's
  models are built in; register others with a factory.
- **Fallback**: a step can name a second model, tried once when the first fails
  or returns invalid output (for example a label outside the list).
- **No code execution**: templates only substitute values. Model output is data.

## Trying it

`RelayPlayground` is a one-window Mac app: pick a sample workflow and a model,
type an input, run it and see each step's result, model and time.

```sh
swift run RelayPlayground
```

## Measuring a model

`relay-bench` runs a few receipts and messages through a model and reports
field accuracy and latency:

```sh
swift run relay-bench apple.on-device
```

## Requirements

Xcode 27 (Swift 6.4), iOS / macOS / visionOS 27. `ModelRelayMLX` also needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## License

Apache 2.0. See `LICENSE`.
