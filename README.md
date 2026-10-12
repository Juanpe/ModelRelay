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
  `classify` (one label), `template` (`{{step.field}}` substitution, no model),
  `request` (an HTTP API call; a JSON response becomes fields), `agent` (a
  model that may call your requests as tools before answering).
- **Values**: typed (`text`, `number`, `bool`, `list`, `dictionary`), so results
  are easy to hand to Shortcuts or any caller.
- **Models**: a `ModelCatalog` maps a `ModelID` to a `LanguageModel`. Apple's
  models are built in; register others with a factory.
- **Fallback**: a step can name a second model, tried once when the first fails
  or returns invalid output (for example a label outside the list).
- **No code execution**: templates only substitute values. Model output is data.

## APIs and cloud models

A `request` step calls an HTTP API. Every part is a template, and values are
escaped for where they land (percent-encoded in the URL, JSON-escaped in a JSON
body), so a model's output can fill a field but never reshape the call.

```swift
Step("weather", .request(HTTPRequest(
    url: "https://api.example.com/weather?q={{input}}",
    headers: [.init("Authorization", "Bearer {{secret.WEATHER_KEY}}")])))
```

- The core has no network code: pass `URLSessionRequestPerformer()` from
  `ModelRelayHTTP` (or your own `RequestPerformer`) to `WorkflowRunner`.
- `{{secret.NAME}}` comes from a `SecretProvider` you supply (for example the
  Keychain), works only in request steps, and is hidden in descriptions.
- Calls that change something (POST, PUT, PATCH, DELETE) are denied unless the
  runner's `WritePolicy` is `.allow` or `.ask { request in … }`. No request is
  ever retried.

An `agent` step gives a model your requests as tools. The model fills each
tool's typed parameters, used in the request as `{{args.NAME}}`:

```swift
let weather = AgentTool(name: "getWeather", description: "Gets the current weather for a city.",
                        parameters: [Field("city", .text)],
                        request: HTTPRequest(url: "https://api.example.com/weather?q={{args.city}}"))
Step("answer", .agent(instruction: "Answer the question.", tools: [weather]), model: .appleOnDevice)
```

Tools follow the same rules as request steps (escaping, secrets, `WritePolicy`).
One agent step makes at most six calls, and once a tool has run, a failure is
not retried on the fallback model, so nothing is done twice.

`ModelRelayCloud` adds `ClaudeModel` and `OpenAICompatibleModel` (OpenAI,
Ollama, LM Studio) as FoundationModels `LanguageModel`s with guided generation:

```swift
let catalog = ModelCatalog()
    .registering("claude") { ClaudeModel(model: "claude-haiku-5-5", apiKey: key) }
    .registering("ollama") { OpenAICompatibleModel(baseURL: URL(string: "http://localhost:11434/v1")!, model: "llama3.2") }
```

## Trying it

`RelayPlayground` is a one-window Mac app: pick a sample workflow and a model,
type an input, run it and see each step's result, model and time.

```sh
swift run RelayPlayground
```

## Serving workflows over HTTP

`relay-serve` loads `Workflow` JSON files from a folder and runs them on
`127.0.0.1`, so other tools (n8n, scripts, Shortcuts' "Get contents of URL") can
use Apple's models:

```sh
swift run relay-serve Examples/workflows --port 8787
curl -s localhost:8787/run/receipt-to-expense -d '{"input": "BLUE BOTTLE … TOTAL EUR 8.30"}'
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
