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
workflow orchestration, typed values, permissions, fallback, tracing and
recoverable execution state, not UI, accounts or storage implementations.
This package still targets Apple OS 27;
provider independence is not a claim of Linux or older-OS support.

## What can you build?

ModelRelay can power a feature inside an ordinary app. Your users do not
need to see a workflow editor: you define the process in Swift, and your
app supplies its interface, data access and approval flow.

### A customer-support inbox

Turn an incoming message into a suggested action and a draft reply:

1. Extract the topic, order number and requested action into typed fields.
2. Use a small model or a decision model to classify urgency and choose a
   workflow branch: billing, delivery or a general question.
3. Let a tool-enabled agent look up the relevant order or knowledge-base
   information through host-configured HTTP or MCP tools.
4. Pass that information and the original message explicitly to another
   model step to draft a reply. It can use a different provider from triage.
5. Show the draft in the app. If the workflow sends it, use a write operation
   guarded by a host-supplied approval policy.

ModelRelay coordinates the branches, data handoff, tools and step records.
A failed model step can try its configured fallback once; a failure after
a tool call does not replay that tool on another model.

### A receipt-to-expense assistant

Turn a photographed receipt into a reviewed expense:

1. Read the image with on-device text recognition or a vision-capable model.
2. Extract the merchant, date, total and tax amounts into typed fields.
3. Classify the expense using a model chosen for that task.
4. Use a compiled `Step.custom` body to validate totals and apply the app's
   business rules, returning validation results as ordinary values.
5. Show the proposed expense for review, then submit it through an approved
   HTTP request or tool call.

The app owns image capture, storage and the review UI. ModelRelay connects
the model steps, deterministic Swift code and submission policy. Custom
bodies are trusted host code, not sandboxed by the write policy, and make
their containing workflow definition non-serializable. The app can reconstruct
it in Swift and separately restore a recoverable execution's data checkpoint.

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

let report = try await WorkflowExecutor().run(workflow, input: .text("BLUE BOTTLE COFFEE\nTOTAL EUR 8.30"))
print(report.output["total"]?.textValue ?? "")   // 8.3
```

This example needs Apple's on-device model to be available. A fallback such
as an MLX or cloud model must first be registered in the executor's catalog.

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
- Create a `WorkflowExecutor` with that catalog and any optional integrations.
- Call `run` with input and optional policy/limits/observers. It returns a `WorkflowExecutionReport`;
  `onStep` receives completed, skipped and failed step records, not token-streaming events.
- Use `start`/`resume` with a host-owned `WorkflowExecutionCheckpointStore` for recovery
  or `requiringApproval` gates. Completed steps are not automatically replayed.
- Encode/decode declarative `Workflow` values if your host needs persistence;
  compiled custom bodies intentionally cannot be serialized.
  ModelRelay does not store workflows, credentials or execution reports.

## Concepts

- **Workflow**: steps that run top to bottom. `ifEquals` and `parallel` are
  blocks that contain steps, so a workflow is a small tree, never a free graph.
- **Execution**: one invocation of that reusable definition, managed by
  `WorkflowExecutor`. `run` returns a `WorkflowExecutionReport`; recoverable
  `start`/`resume` return a `WorkflowExecutionOutcome` and use a
  `WorkflowExecutionCheckpoint`. Each checkpoint's `executionID` identifies
  that invocation, while `workflowID` identifies its definition.
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
`WorkflowBuilder` is syntax sugar, not a validator. The executor validates
definitions before execution; use `await executor.validate(workflow)` to
preview diagnostics. `referenceIssues` remains available for reference-only checks.

## Execution and context

- Each run has its own input, previous value, named results and step records.
  Reusing an executor does not retain a conversation between runs.
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
  result is returned. An invalid explicit output is rejected, not silently
  replaced with the last result. Missing template references also fail explicitly.

`stepTimeout` defaults to 30 seconds per bounded operation, not per workflow.
A fallback has its own attempt. Timeouts and task cancellation are cooperative;
an adapter must respond to cancellation. These are not background-execution
guarantees and cannot override deadlines imposed by the host OS or caller.

See [SDK integration](Documentation/Integration.md) for ownership, model
resources, MCP authentication and the current limitations.

### Validation, events and limits

```swift
let executor = WorkflowExecutor(limits: .init(
    maxDuration: .seconds(60), maxModelCalls: 8,
    maxToolCalls: 12, maxConcurrentSteps: 2
))
let issues = await executor.validate(workflow) // No model factories or MCP discovery.
let report = try await executor.run(workflow, input: input,
    onEvent: { event in print(event.kind.rawValue, event.step ?? "") })
print(report.executionID, report.usage.modelCalls, report.usage.toolCalls)
```

Invalid definitions throw `WorkflowValidationError` before work. Operational
failures retain typed causes in `RelayError.operationFailed`; serializable
summaries go into step records, not raw errors. Metadata-only events cover
steps, models, tools, fallback, approvals and successful checkpoint saves.
Events contain no prompts, arguments, results or raw error messages.

Limits are shared across parallel branches and cannot be expanded on resume.
They count executor-mediated attempts, not hidden provider HTTP rounds or tokens.
Duration/cancellation are cooperative; a cutoff never proves a write failed.
See [execution safety](Documentation/ExecutionSafety.md) for exact semantics,
typed error handling, sensitive-data boundaries and checkpoint accounting.

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
let executor = WorkflowExecutor(requests: URLSessionRequestPerformer())
// Supply your API's real URL before calling executor.run(workflow, input: ...).
```

- The core has no network code: pass `URLSessionRequestPerformer()` from
  `ModelRelayHTTP` (or your own `RequestPerformer`) to `WorkflowExecutor`.
- `{{secret.NAME}}` comes from a `SecretProvider` you supply (for example the
  Keychain), works only in request steps, and is hidden in descriptions.
- Calls that change something (POST, PUT, PATCH, DELETE) are denied unless the
  executor's `WritePolicy` is `.allow` or `.ask { request in … }`. No request is
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
(`.agent(instruction:tools:kits:)`) and the executor is given the kits.

### Explicit conversations and handoff

Steps are isolated by default. Opt into one native conversation within a run:

```swift
let workflow = Workflow("Draft and review") {
    Step.agent("draft", "Write a short answer.", model: .appleOnDevice)
        .withContext(.conversation("writer"))
    Step.agent("review", "Review your previous answer.", input: "input", model: .appleOnDevice)
        .withContext(.conversation("writer"))
    Step.prompt("editor", "Edit only the selected result.", model: "editor")
        .withContext(.handoff(["review"]))
}
```

The first two steps reuse the same native session. The editor starts fresh,
receiving a dictionary of selected values, not the previous input or tool
history. Do not combine handoff with an explicit `input`. Explicit instruction
templates still work as usual. The `editor` model must be registered.

Conversations are keyed by **name and model ID**, never shared across runs.
A different provider, including a fallback, has its own history: ModelRelay
never silently replays another provider's opaque transcript. Use handoff
for intentional cross-model context transfer. Parallel branches cannot use
the same conversation/model; this is rejected before execution.

Model/decision factories are coalesced and cached once per ID within an active
run invocation. Resuming after a pause creates fresh resource caches lazily.
A timed-out waiter does not cancel another step's pending load. Return a
shared backend if you want resource reuse across runs; weights and KV-cache
behavior still belong to the provider. Each step rebinds its current tools,
permissions, argument resolver and call budget; old tool wrappers are not reused.
Resuming a recoverable execution restores its explicit histories as part of
the same logical run, rather than sharing them with an unrelated run.

### Execution and data policies

```swift
let executor = WorkflowExecutor(policy: .localOnly)
let workflow = Workflow("Private review") {
    Step.prompt("draft", "Summarize.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
    Step.agent("review", "Review the summary.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
        .withPolicy(.readOnly)
}
```

- `.localOnly` requires a model explicitly declared local and blocks all
  executor-mediated HTTP/MCP operations, including reads. A remote or unspecified
  fallback is blocked **before its factory runs**, not merely before inference.
- `.readOnly` removes write tools from agents and rejects write requests/tool
  calls. `.noTools` also blocks reads and avoids MCP connections. WritePolicy
  approval cannot override these restrictions.
- Apply policy to the executor, narrow one `run(..., policy:)`, or narrow a
  step/block with `withPolicy`.
  Children cannot relax parent restrictions. A local-only result stays local
  through references, templates, handoffs, branches, merges and conversations.
  Custom outputs conservatively inherit all data accessible in their context.
- Model registration accepts `location: .local`, `.remote` or `.unspecified`.
  On-device/OCR and MLX presets are local; Private Cloud Compute is remote.
  Locality is a host assertion, not inferred from a URL or model name.
- This is **not a sandbox or automatic PII detection**. Trusted providers,
  custom bodies, callbacks and captured host resources remain your responsibility.
  MCP read-only metadata must be trustworthy; it cannot prove a remote tool's
  actual behavior. Labels are run-local: carry `WorkflowExecutionReport.outputDataAccess`
  into the next run's policy when handing its output to another run.

See [context and policy semantics](Documentation/ContextAndPolicies.md) for
fallback, concurrency, privacy propagation and trust boundaries.

### Checkpoints and human review

```swift
// Keep the workflow UUID stable across invocations. The host supplies `store`.
let workflow = Workflow("Review summary", id: workflowID) {
    Step.prompt("draft", "Summarize the article.", model: .appleOnDevice)
    Step.template("approved", "{{draft}}")
        .requiringApproval("Review the summary before continuing")
}

let outcome = try await executor.start(workflow, input: article,
                                     revision: "summary-v1", store: store)
// If outcome is .awaitingApproval(checkpoint), show checkpoint.results["draft"].
// Later, after the host obtains a decision (possibly with a new executor):
// try await executor.resume(workflow, from: checkpoint, revision: "summary-v1",
//                         approval: .approve, store: store)
```

The host implements **atomic, durable compare-and-swap** saves. Checkpoints
retain confirmed values, privacy labels, records and native conversation
history, not credentials, model resources or executable closures. Approval
does not override write/privacy policies. Ordinary `run` rejects approval gates.

Boundaries are top-level steps; a branch/parallel block is one recovery unit.
An interrupted operation is **never replayed automatically**: a write may have
succeeded before its result was saved. After external verification, the host
can confirm a leaf's result without rerunning it. There is no exactly-once or
OS background-execution guarantee. See [recovery semantics and storage contract](Documentation/Recovery.md).

## Images

A `readImage` step sends an image (its input must be `Value.image`) and an
instruction to a model that can see, and returns its text. An empty
instruction asks for all the text, as written. The step's record says what
the image was, never its bytes.

```swift
import Foundation
import ModelRelay

func readReceipt(_ jpeg: Data, using executor: WorkflowExecutor) async throws -> WorkflowExecutionReport {
    let workflow = Workflow("Read receipt") {
        Step.readImage("receipt", instruction: "Read the total.",
                       model: "claude", fallback: .appleTextRecognition)
    }
    return try await executor.run(workflow, input: .image(ImageValue(data: jpeg, contentType: "image/jpeg")))
}
```

The supplied executor must register `claude` as a vision-capable model.

- Native AnyLanguageModel providers encode the image for their APIs. Choose
  a model that actually supports vision and register it with
  `supportsImages: true`. The executor validates and normalizes the input
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
let report = try await WorkflowExecutor().run(workflow, input: .text("  Article text  "))
```

- The body is `@Sendable (CustomStepContext) async throws -> Value`.
  `input:` can select an earlier result; otherwise it reads the previous
  step's output. `results` and the subscript expose completed steps only.
- Bodies run once, on the selected branch, with ordinary step records,
  cooperative cancellation and timeout. No fallback or automatic replay.
- Custom bodies are **trusted developer code**, with the host's authority.
  They are not sandboxed by `WritePolicy`. The context contains values, not
  the executor's transports or secrets; closures can still capture host resources.
- Workflow definitions containing custom bodies are **in-memory only**. Encoding
  fails explicitly, including nested bodies. JSON cannot reconstruct a closure.
  Declarative-only workflows remain Codable. Reference renaming cannot
  inspect keys hardcoded inside a closure. For recovery, reconstruct that
  definition in Swift and restore its separate data checkpoint; bump the host
  revision when executable bodies or captures change.
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

func makeToolExecutor(secrets: any SecretProvider, writePolicy: WritePolicy) -> WorkflowExecutor {
    let issues = ToolKit(id: "issues", name: "Issues", tools: [],
        server: ToolServer(url: "https://mcp.example.com/mcp",
                           headers: [.init("Authorization", "Bearer {{secret.ISSUES_KEY}}")]))
    return WorkflowExecutor(writePolicy: writePolicy, toolKits: [issues],
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

func makeDecisionExecutor(apiKey: String) -> WorkflowExecutor {
    let catalog = ModelCatalog().registering(decisions: "jev") { DecisionsAPIModel(apiKey: apiKey) }
    return WorkflowExecutor(catalog: catalog)
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

func makeCloudExecutor(baseURL: URL, modelName: String, apiKey: String) -> WorkflowExecutor {
    let model = OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: modelName)
    let catalog = ModelCatalog().registering("writer") { model }
    return WorkflowExecutor(catalog: catalog)
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
