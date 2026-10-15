![ModelRelay — Composable AI workflows for Swift](.github/assets/modelrelay-banner.png)

# ModelRelay

Chain small language-model steps — prompt, extract, classify, branch, run in
parallel — and let every step use the smallest model that does the job.

ModelRelay uses [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)
as its native inference and conversation runtime: Apple's on-device model,
Private Cloud Compute, Claude, OpenAI-compatible servers and optional local
MLX models all use the same session API. There is no second session runtime
or transcript bridge inside ModelRelay.

ModelRelay is a standalone SDK, not an application framework. It owns
workflow orchestration, typed values, permissions, fallback and tracing,
not UI, accounts or persistence. This package still targets Apple OS 27;
provider independence is not a claim of Linux or older-OS support.

## Installation

Add this repository once with Swift Package Manager, then select only the
products your target uses. The following manifest uses the development
branch, not a pinned release:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MyClient",
    platforms: [.macOS(.v27), .iOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/Juanpe/ModelRelay.git", branch: "main", traits: []),
    ],
    targets: [
        .target(name: "MyClient", dependencies: [
            .product(name: "ModelRelay", package: "ModelRelay"),
        ]),
    ]
)
```

There is **one package**, with these separately importable products:

| Product / import | Use it for | Dependencies beyond the core |
| --- | --- | --- |
| `ModelRelay` | Workflow values, builders, execution, native model registration, custom bodies | AnyLanguageModel |
| `ModelRelayHTTP` | Sending HTTP request steps and HTTP agent tools | Foundation / URLSession |
| `ModelRelayCloud` | Specialized decisions API, including Jev | Foundation / URLSession |
| `ModelRelayMCP` | MCP tools over Streamable HTTP and OAuth helpers | Foundation / URLSession, CryptoKit |
| `ModelRelayMLX` | Convenience presets for native MLX providers | AnyLanguageModel MLX backend; enable the `MLX` trait |

For ordinary cloud generation, register AnyLanguageModel's providers directly;
`ModelRelayCloud` is only needed for specialized decision models. ModelRelay
has one direct third-party package dependency: AnyLanguageModel. SwiftScript
and ShellKit are not dependencies. AnyLanguageModel itself uses SwiftSyntax
for its macros and has its own transitive/optional backend dependencies.
Selecting fewer products avoids compiling/linking unused targets, not all
SwiftPM dependency resolution.

MLX is **disabled by default**. To use it, add the `ModelRelayMLX` product
and replace `traits: []` with `traits: ["MLX"]` on the package dependency.
Existing clients relying on the old MLX default must now enable it explicitly.

## Basic usage

```swift
import ModelRelay

let workflow = Workflow("Receipt to expense") {
    Step.extract("expense", instruction: "Extract the expense from this receipt.", model: .appleOnDevice) {
        Field("merchant", .text)
        Field("total", .number)
        Field("currency", .choice(["EUR", "USD", "GBP"]))
    }
}

let report = try await WorkflowRunner().run(workflow, input: .text("BLUE BOTTLE COFFEE\nTOTAL EUR 8.30"))
print(report.output["total"]?.textValue ?? "")   // 8.3
```

This example needs Apple's on-device model to be available. A fallback such
as an MLX or cloud model must first be registered in the runner's catalog.

For a complete consumer package that runs without credentials or a model,
see [StandaloneClient](Examples/StandaloneClient). From this checkout:

```sh
swift run --package-path Examples/StandaloneClient StandaloneClient
# Optional: use Apple's real on-device model instead of the deterministic step.
swift run --package-path Examples/StandaloneClient StandaloneClient --apple
```

### Entry points

- Build data with `Workflow`, `Step`, `Field` and `Value`, using arrays or builders.
- Register model factories in `ModelCatalog`. The default catalog includes
  Apple's on-device model, Private Cloud Compute and text recognition.
- Create a `WorkflowRunner` with that catalog and any optional integrations.
- Call `run(_:input:onStep:)`. It returns a `RunReport`; `onStep` receives
  completed, skipped and failed step records, not token-streaming events.
- Encode/decode declarative `Workflow` values if your host needs persistence;
  compiled custom bodies intentionally cannot be serialized.
  ModelRelay does not store workflows, credentials or execution reports.

## Concepts

- **Workflow**: steps that run top to bottom. `ifEquals` and `parallel` are
  blocks that contain steps, so a workflow is a small tree, never a free graph.
- **Step**: `prompt` (text), `extract` (typed fields, guided generation),
  `classify` (one label), `template` (`{{step.field}}` substitution, no model),
  `request` (an HTTP API call; a JSON response becomes fields), `agent` (a
  model that may call your requests as tools before answering), `decide`
  (typed questions answered at once), `switchOn` (a path per value),
  `readImage` (the text in an image, read by a model that can see), `custom`
  (a trusted developer-supplied Swift body), `useTool` (one tool of a tool set,
  called with values you give it, no model).
- **Values**: typed (`text`, `number`, `bool`, `list`, `dictionary`, `image`),
  so results are easy to hand to any caller. Models read lists
  and fields as JSON; templates meant for people read them as text.
- **Models**: a `ModelCatalog` maps a `ModelID` to a `LanguageModel`. Apple's
  models are built in; register others with a factory.
- **Fallback**: a step can name a second model, tried once when the first fails
  or returns invalid output (for example a label outside the list).
- **Model output is never executed**: templates only substitute values.
  Custom steps run only compiled code the developer supplied, not model text.

## Declarative composition

`WorkflowBuilder` collects ordinary `Step` values. The original array-based
initializers remain available, and both forms produce the same workflow values: no model calls during
construction. Declarative-only workflows are Codable; custom closures are not.

```swift
let workflow = Workflow("Analyze article", output: "result") {
    Step.parallel("analysis") {
        Step.prompt("summary", "Summarize in three bullet points.", model: .appleOnDevice)
        Step.classify("tone", "Identify the tone.",
                      labels: ["positive", "neutral", "negative"], model: .appleOnDevice)
    }
    Step.template("result", "{{summary}}\nTone: {{analysis.tone}}")
}
```

Step helpers cover `prompt`, `extract`, `classify`, `template`, `agent`,
`decide`, `request`, `ifEquals`, `switchOn`, `parallel`, `readImage`, `custom`
and `useTool`. `extract` uses `FieldBuilder`; an existing `[Field]` can be
inserted directly into its block. A workflow block can likewise include an
existing `Step` or `[Step]`, and Swift `if`, `switch`, `for`, and availability
checks. These run **when building the workflow**, not on a model's result.

For decisions during execution, build an explicit conditional or switch node:

```swift
let workflow = Workflow("Route message") {
    Step.classify("kind", "Is this urgent?", labels: ["urgent", "later"], model: .appleOnDevice)
    Step.ifEquals("route", reference: "kind", value: "urgent") {
        Step.template("urgent", "Needs attention: {{input}}")
    } otherwise: {
        Step.template("later", "For later: {{input}}")
    }
}
```

`Step.switchOn` accepts `[SwitchCase]`; `SwitchCase("value") { ... }`
builds a case's steps. The trailing block of `Step.switchOn` builds its default branch.
`WorkflowBuilder` is syntax sugar, not a validator: check `referenceIssues`
before execution and keep step names unique, just as with array-built workflows.

## Execution and context

- Each run has its own input, previous value, named results and step records.
  Reusing a runner does not retain a conversation between runs.
- A step with no explicit `input` receives the previous result. Use
  `input: "input"` for the original input, `input: "expense"` for a named
  result, or `input: "expense.total"` for one of its fields.
- Templates can read earlier results as `{{expense.total}}`. If a model
  instruction contains template markers, the rendered instruction is the
  **entire prompt**: include `{{input}}` yourself when it is needed.
- Parallel children read the same incoming snapshot, not each other's
  results. The block returns a dictionary keyed by child name; after it,
  results are available as `{{analysis.tone}}` or `{{tone}}`.
- `output: "result"` selects a named step's full result. Without it, the last
  result is returned. An unresolved output name currently also falls back to
  the last result; validate references before execution.

`stepTimeout` defaults to 30 seconds per bounded operation, not per workflow.
A fallback has its own attempt. Timeouts and task cancellation are cooperative;
an adapter must respond to cancellation. These are not background-execution
guarantees and cannot override deadlines imposed by the host OS or caller.

See [SDK integration](Documentation/Integration.md) for ownership, model
resources, MCP authentication and the current limitations.

## APIs and cloud models

A `request` step calls an HTTP API. Every part is a template, and values are
escaped for where they land (percent-encoded in the URL, JSON-escaped in a JSON
body), so a model's output can fill a field but never reshape the call. In a
JSON body, a value inside quotes goes in as text; a value on its own
(`"expense": {{expense}}`) goes in as JSON, so fields, lists and numbers keep
their types.

```swift
import ModelRelay
import ModelRelayHTTP

let workflow = Workflow("Weather") {
    Step.request("weather", HTTPRequest(url: "https://api.example.com/weather?q={{input}}"))
}
let runner = WorkflowRunner(requests: URLSessionRequestPerformer())
// Supply your API's real URL before calling runner.run(workflow, input: ...).
```

- The core has no network code: pass `URLSessionRequestPerformer()` from
  `ModelRelayHTTP` (or your own `RequestPerformer`) to `WorkflowRunner`.
- `{{secret.NAME}}` comes from a `SecretProvider` you supply (for example the
  Keychain), works only in request steps, and is hidden in descriptions.
- Calls that change something (POST, PUT, PATCH, DELETE) are denied unless the
  runner's `WritePolicy` is `.allow` or `.ask { request in … }`. No request is
  ever retried.
- `HTTPRequest(url: "{{input}}", reading: .page)` reads a web page: the result
  is its title and readable text, without scripts, menus or markup. A URL
  that is a single reference is used as given (it must be http or https).

An `agent` step gives a model your requests as tools. The model fills each
tool's typed parameters, used in the request as `{{args.NAME}}`:

```swift
let weather = AgentTool(name: "getWeather", description: "Gets the current weather for a city.",
                        parameters: [Field("city", .text)],
                        request: HTTPRequest(url: "https://api.example.com/weather?q={{args.city}}"))
let step = Step.agent("answer", "Answer the question.", tools: [weather], model: .appleOnDevice)
```

Tools follow the same rules as request steps (escaping, secrets, `WritePolicy`).
One agent step makes at most six calls, and once a tool has run, a failure is
not retried on the fallback model, so nothing is done twice.

Tools can be grouped in a `ToolKit` and shared: an agent names kits by id
(`.agent(instruction:tools:kits:)`) and the runner is given the kits.

### Reusing agents and model sessions

An agent is a step's configuration, not a persistent actor or conversation.
Reuse the same tools, kit IDs and model ID in multiple steps, or wrap that
configuration in a function that returns a `Step`:

```swift
func assistant(_ name: String, instruction: String, input: String? = nil) -> Step {
    Step.agent(name, instruction, kits: ["research"], input: input, model: "writer")
}

let workflow = Workflow("Draft and review") {
    assistant("draft", instruction: "Write a short answer.")
    assistant("review", instruction: "Review and improve the draft.")
}
```

Here the runner must have a registered `writer` model and a `research` tool
kit. Each agent step creates a **fresh `LanguageModelSession`**. The review
step receives the draft as its input value, not the draft's full conversation
or tool-call history. Use `input: "input"` to read the original workflow
input instead, or templates to pass selected earlier results explicitly.

Model factories may return a shared model instance or backend; fresh sessions
do not themselves require downloading or loading model weights twice. Within
one agent step, tool calls and their results belong to that step's session.
Conversation memory between steps or runs is not managed by ModelRelay.

There is no separate named `Agent` object or automatic handoff of an entire
workflow transcript today. Share selected results explicitly; a different
agent receives only the input and prompt you give its step.

## Images

A `readImage` step sends an image (its input must be `Value.image`) and an
instruction to a model that can see, and returns its text. An empty
instruction asks for all the text, as written. The step's record says what
the image was, never its bytes.

```swift
import Foundation
import ModelRelay

func readReceipt(_ jpeg: Data, using runner: WorkflowRunner) async throws -> RunReport {
    let workflow = Workflow("Read receipt") {
        Step.readImage("receipt", instruction: "Read the total.",
                       model: "claude", fallback: .appleTextRecognition)
    }
    return try await runner.run(workflow, input: .image(ImageValue(data: jpeg, contentType: "image/jpeg")))
}
```

The supplied runner must register `claude` as a vision-capable model.

- Native AnyLanguageModel providers encode the image for their APIs. Choose
  a model that actually supports vision and register it with
  `supportsImages: true`. The runner validates and normalizes the input
  image before handing it to the native session.
- `.appleTextRecognition` reads it on device with Vision: nothing leaves the
  device and the instruction is ignored. Its first use in an app prepares
  its model (up to a minute on a Mac); `TextRecognitionModel.prepare()`
  does that ahead of time.
- A catalog entry without image support fails before inference and can use
  its one fallback model. Built-in Apple entries check their native support.

## Custom Swift steps

Define a step's body directly in Swift. No interpreter, source strings,
script runner or runtime adapter is required:

```swift
import Foundation
import ModelRelay

let workflow = Workflow("Normalize and summarize") {
    Step.custom("normalized") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    Step.prompt("summary", "Summarize this article.", model: .appleOnDevice)
    Step.custom("message") { context in
        .dictionary([
            "summary": context.input,
            "original": context.workflowInput,
            "normalized": context["normalized"] ?? .null,
        ])
    }
}
let report = try await WorkflowRunner().run(workflow, input: .text("  Article text  "))
```

- The body is `@Sendable (CustomStepContext) async throws -> Value`.
  `input:` can select an earlier result; otherwise it reads the previous
  step's output. `results` and the subscript expose completed steps only.
- Bodies run once, on the selected branch, with ordinary step records,
  cooperative cancellation and timeout. No fallback or automatic replay.
- Custom bodies are **trusted developer code**, with the host's authority.
  They are not sandboxed by `WritePolicy`. The context contains values, not
  the runner's transports or secrets; closures can still capture host resources.
- Workflows containing custom bodies are **in-memory only**. Encoding fails
  explicitly, including nested bodies. JSON cannot reconstruct a closure.
  Declarative-only workflows remain Codable. Reference renaming cannot
  inspect keys hardcoded inside a closure.
- A client wanting a code editor/interpreter can invoke its own runtime from
  a custom body. ModelRelay neither chooses that runtime nor executes model
  output as code. Blocking bodies cannot be forcibly terminated by a timeout.

## MCP servers

A `ToolKit` with a `server` gets its tools from an MCP server (Streamable
HTTP) when a step runs. Agents can call them, and a `useTool` step calls one
directly.

```swift
import ModelRelay
import ModelRelayMCP

func makeToolRunner(secrets: any SecretProvider, writePolicy: WritePolicy) -> WorkflowRunner {
    let issues = ToolKit(id: "issues", name: "Issues", tools: [],
        server: ToolServer(url: "https://mcp.example.com/mcp",
                           headers: [.init("Authorization", "Bearer {{secret.ISSUES_KEY}}")]))
    return WorkflowRunner(writePolicy: writePolicy, toolKits: [issues],
                          toolServers: MCPConnector(secrets: secrets))
}

let workflow = Workflow("File issue") {
    Step.useTool("file", kit: "issues", tool: "create_issue", arguments: ["title": "{{input}}"])
}
```

- Tools the server doesn't mark read-only count as writes: the
  `WritePolicy` decides, and a call is never retried.
- `MCPSignIn` provides OAuth building blocks: discovery, optional dynamic
  registration, PKCE, code exchange and refresh. You can use a preregistered
  `Client` or your own OAuth implementation. The host opens the page, validates
  its callback, securely stores tokens and coordinates refresh;
  `MCPConnector.accessToken` asks for the current token on connection.
- This is a tools connector, not a full MCP SDK. It currently initializes
  with protocol `2025-06-18`; resources, prompts, stdio and complete conformance
  with later OAuth specifications are not implemented. See the
  [authentication contract and limitations](Documentation/Integration.md#mcp-and-oauth).

## Decisions

A `decide` step asks typed questions about its text in one go: yes/no, one
of some options, or a level. A `DecisionModel` such as TypeSafe's Jev (through
Vercel AI Gateway, `DecisionsAPIModel` in `ModelRelayCloud`) answers with how
sure it is; any language model answers the same questions with a guided
schema, so the step also works offline and can fall back to Apple's model.

```swift
import ModelRelay
import ModelRelayCloud

func makeDecisionRunner(apiKey: String) -> WorkflowRunner {
    let catalog = ModelCatalog().registering(decisions: "jev") { DecisionsAPIModel(apiKey: apiKey) }
    return WorkflowRunner(catalog: catalog)
}

let workflow = Workflow("Triage ticket") {
    Step.decide("ticket", questions: [
        Question("damaged", "Does the customer report a damaged item?", .yesNo),
        Question("team", "Which team should handle it?", .choice([.init("billing"), .init("shipping")])),
        Question("urgency", "How urgent is it?", .score(["low", "medium", "high"])),
    ], model: "jev", fallback: .appleOnDevice)
}
```

Decision models answer typed questions; they do not generate summaries or
act as general-purpose agents.

For general inference, use native AnyLanguageModel providers directly:

```swift
import AnyLanguageModel
import Foundation
import ModelRelay

func makeCloudRunner(baseURL: URL, modelName: String, apiKey: String) -> WorkflowRunner {
    let model = OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: modelName)
    let catalog = ModelCatalog().registering("writer") { model }
    return WorkflowRunner(catalog: catalog)
}

let workflow = Workflow("Cloud summary") {
    Step.prompt("summary", "Summarize in three bullet points.", model: "writer")
}
```

Choose a server-supported model and pass credentials at runtime, never in
workflow JSON. For Anthropic use `AnthropicLanguageModel(apiKey: apiKey,
model: modelName)`. When importing providers directly, declare
AnyLanguageModel and its product in your client's SwiftPM dependencies too;
both packages resolve the same AnyLanguageModel 1.0.0 dependency, not two copies.
ModelRelay does not wrap these providers or translate their transcripts.

## Trying it

`RelayPlayground` is a one-window Mac app: pick a sample workflow and a model,
type an input, run it and see each step's result, model and time.

```sh
swift run RelayPlayground
# Opt in to local MLX models (and first-use weight downloads).
swift run --traits MLX RelayPlayground
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
# With the optional MLX integration:
swift run --traits MLX relay-bench mlx:qwen3-0.6b
```

## Testing

```sh
env -u RELAY_LIVE swift test -Xswiftc -warnings-as-errors
```

The default tests use scripted native AnyLanguageModel sessions and stubbed HTTP,
not real models, services or credentials. Live Apple-model tests are opt-in
with `RELAY_LIVE=1`. MLX runtime/Metal support needs separate verification
with the `MLX` trait on supported hardware.

### Native runtime migration

See [the migration notes](Documentation/NativeRuntimeMigration.md) for the
breaking API changes, custom-step boundaries and verification scope. The
former double-runtime compatibility experiment has been retired.

## Requirements

Xcode 27 (Swift 6.4), iOS / macOS / visionOS 27. `ModelRelayMLX` also needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## License

MIT. See [LICENSE](LICENSE).
