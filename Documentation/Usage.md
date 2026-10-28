# 🧩 Usage recipes

[← README](../README.md) · [Integration](Integration.md) · [Safety](ExecutionSafety.md)

Pick a recipe and add the integrations it needs. Models used by a step must
be available in your executor's catalog.

[🎯 Steps](#step-types) · [🔀 Branches](#composition) · [📦 Values](#values-and-input) ·
[🧾 Nested fields](#nested-fields) · [🌐 HTTP](#http-requests-and-agent-tools) · [☁️ Cloud](#cloud-models) ·
[📷 Images](#images) · [👨‍💻 Swift](#custom-swift) · [🧰 MCP](#mcp-tools-and-oauth) · [🗳 Decisions](#decision-models)

<a name="step-types"></a>

## 🎯 Pick a step

| Step | Result |
| --- | --- |
| `prompt` | Generated text |
| `extract` | Typed fields |
| `classify` | One label |
| `decide` | Typed answers to several questions |
| `agent` | An answer after optional tool calls |
| `readImage` | Text from a vision model or on-device OCR |
| `template` | Substituted text, no model |
| `request` | An HTTP result; JSON becomes typed values |
| `useTool` | One direct named tool call, no model |
| `custom` | Your compiled Swift result |
| `ifEquals` / `switchOn` | The selected branch's result |
| `parallel` | A dictionary of child results |

Constructing the tree runs no model or tool. Declarative workflows are Codable;
compiled custom bodies are not.

<a name="composition"></a>

## 🔀 Choose a path

Swift `if`/`switch`/`for` inside a builder runs at **construction time**.
To branch on a model's answer during **execution**, use a workflow step:

```swift
import ModelRelay

let workflow = Workflow(
    name: "Route message"
) {
    Step.classify("kind", "Is this urgent?", labels: ["urgent", "later"], model: .appleOnDevice)
    Step.ifEquals("route", reference: "kind", value: "urgent") {
        Step.template("urgent", "Needs attention: {{input}}")
    } otherwise: {
        Step.template("later", "For later: {{input}}")
    }
}
```

For more paths, use `Step.switchOn` with `[SwitchCase]`; its trailing block
is the default branch. Builders also accept reusable steps/arrays, optional
branches and availability checks. `FieldBuilder` accepts existing fields.

Execution validates automatically. Use `await executor.validate(workflow)`
for diagnostics, or `referenceIssues` for reference-only checks.

<a name="values-and-input"></a>

## 📦 Pass values between steps

| Read… | With… |
| --- | --- |
| Previous result | Leave `input` unset |
| Original input | `input: "input"` |
| A result / field | `input: "expense"` / `input: "expense.total"` |
| A value inside text | `{{expense.total}}` |
| A parallel result | `{{analysis.tone}}` or `{{tone}}` |

`Value` supports text, number, bool, list, dictionary and image. Models read
structured values as JSON; text templates format them for people.

> 📣 Template markers make the rendered instruction the **entire prompt**.
> Include `{{input}}` yourself when the model needs it.

Parallel children read the same snapshot, not each other's results.
`output: "result"` selects that step's whole value; omitting it returns the
last result. Missing references or invalid explicit outputs fail rather than
silently substituting another value.

Executions are independent. Opt into [conversation/handoff](ContextAndPolicies.md)
for shared history or selected context. `stepTimeout` defaults to 30 seconds
per bounded operation, not per workflow; cancellation remains cooperative.

<a name="nested-fields"></a>

## 🧾 Extract lists of objects

Group fields with `.object`. A list of objects reads records such as the lines of an order:

```swift
let workflow = Workflow(
    name: "Order from text"
) {
    Step.extract("order", instruction: "Turn the order into lines.", model: .appleOnDevice) {
        Field("lines", .list(.object([
            Field("product", .choice(["Beer", "Cola", "Fries"])),
            Field("quantity", .number),
            Field("note", .text),
        ])))
    }
}
```

Each object becomes a dictionary (`{{order.lines}}` inserts the list as JSON).
Objects work wherever fields do, including tool parameters. Nested field names
only need to be unique within their object.

<a name="http-requests-and-agent-tools"></a>

## 🌐 Call an HTTP API

Add `ModelRelayHTTP` and supply its request performer:

```swift
import ModelRelay
import ModelRelayHTTP

let workflow = Workflow(
    name: "Weather"
) {
    Step.request("weather", HTTPRequest(url: "https://api.example.com/weather?q={{input}}"))
}
let executor = WorkflowExecutor(requests: URLSessionRequestPerformer())
```

Replace example URLs before running. You can also supply your own
`RequestPerformer`.

| Template | Behavior |
| --- | --- |
| URL `{{input}}` | Percent-encoded substitution |
| JSON `"name": "{{expense.merchant}}"` | Escaped text |
| JSON `"expense": {{expense}}` | Typed JSON value |
| `{{secret.NAME}}` | Host-provided request credential, hidden in descriptions |
| Whole URL + `reading: .page` | HTTP(S) page title/readable text, without scripts or markup |

> 🔒 Supply a `SecretProvider`; never embed credentials in workflow JSON.
> Writes need an explicit `WritePolicy`. Requests/tools are never retried,
> and a timeout cannot prove a remote write failed.

### 🧰 Give an agent a tool

The model fills typed parameters. The request reads them as `{{args.NAME}}`:

```swift
import ModelRelay

let weather = AgentTool(
    name: "getWeather",
    description: "Gets the current weather for a city.",
    parameters: [Field("city", .text)],
    request: HTTPRequest(url: "https://api.example.com/weather?q={{args.city}}")
)
let workflow = Workflow(
    name: "Weather assistant"
) {
    Step.agent("answer", "Answer the question.", tools: [weather], model: .appleOnDevice)
}
```

Run with a request performer. Tools share the same escaping, secrets and write
policy as requests. The step permits six tool calls; a host tool attempt
prevents fallback. This is not an exactly-once guarantee.

Group reusable tools in a `ToolKit`, pass it to the executor and select it
with `kits: ["weather"]`.

<a name="cloud-models"></a>

## ☁️ Choose your models

Register native providers in a `ModelCatalog`, then use their IDs in steps.
The [models guide](Models.md) covers [Ollama](Models.md#ollama),
[OpenAI and Anthropic](Models.md#cloud), [compatible servers](Models.md#compatible-servers),
[Apple](Models.md#apple), [MLX](Models.md#mlx) and [Jev](Models.md#jev),
including package setup and a mixed-model workflow.

<a name="images"></a>

## 📷 Read an image

`readImage` takes `Value.image` and returns text. An empty instruction asks
for all text as written:

```swift
import Foundation
import ModelRelay

func readReceipt(_ jpeg: Data, using executor: WorkflowExecutor) async throws -> WorkflowExecutionReport {
    let workflow = Workflow(
        name: "Read receipt"
    ) {
        Step.readImage("receipt", instruction: "Read the total.",
                       model: "claude", fallback: .appleTextRecognition)
    }
    return try await executor.run(workflow, input: .image(ImageValue(data: jpeg, contentType: "image/jpeg")))
}
```

| Model | Setup / behavior |
| --- | --- |
| Your vision model | Register with `supportsImages: true`; the actual model must support vision |
| `.appleTextRecognition` | On-device Vision; ignores instructions; call `TextRecognitionModel.prepare()` to warm up |

The executor validates/normalizes images; native providers encode them.
Missing image capability can use the step's one fallback.
Records describe images without retaining their bytes.

> 🔒 OCR keeps that step local. Later steps still need their own privacy policy.

<a name="custom-swift"></a>

## 👨‍💻 Write a Swift body

No model needed for trimming text or checking your business rules:

```swift
import Foundation
import ModelRelay

let workflow = Workflow(
    name: "Normalize text"
) {
    Step.custom("normalized") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

The body is `@Sendable (CustomStepContext) async throws -> Value`.

| Context member | Reads |
| --- | --- |
| `input` | Previous result, or your explicit `input:` selection |
| `workflowInput` | Original input |
| `results` / `context["step"]` | Completed named results |

Bodies run once on the selected path, with records and cooperative cancellation.
No fallback or automatic replay.

> ⚠️ Trusted host code, not a sandbox. Closures can capture resources even
> though the context exposes no executor secrets/transports. Never evaluate
> model-generated source; blocking code cannot be forcibly timed out.

Custom definitions cannot be serialized, including nested closures.
Rebuild them in Swift for [recovery](Recovery.md) and bump the host revision
when bodies/captures change. Renaming cannot rewrite hardcoded closure keys.
A client may call its own interpreter here; the SDK does not depend on one.

<a name="mcp-tools-and-oauth"></a>

## 🧰 Use an MCP tool

Add `ModelRelayMCP`. Agents can use discovered tools, or call one directly:

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

let workflow = Workflow(
    name: "File issue"
) {
    Step.useTool("file", kit: "issues", tool: "create_issue", arguments: ["title": "{{input}}"])
}
```

Tools not marked read-only count as writes and need authorization.
They are not retried.

For OAuth, provide `MCPConnector.accessToken` from your OAuth client or use
the optional `MCPSignIn` helpers. Your host owns the browser, callback checks,
secure storage and serialized refresh.
[Authentication contract and connector limits →](Integration.md#mcp-and-oauth)

<a name="decision-models"></a>

## 🗳 Ask typed questions

Need yes/no, choices or scores rather than a generated paragraph?

```swift
import ModelRelay
import ModelRelayCloud

let workflow = Workflow(
    name: "Triage ticket"
) {
    Step.decide("ticket", questions: [
        Question("damaged", "Does the customer report a damaged item?", .yesNo),
        Question("team", "Which team should handle it?", .choice([.init("billing"), .init("shipping")])),
        Question("urgency", "How urgent is it?", .score(["low", "medium", "high"])),
    ], model: CloudModels.jev, fallback: .appleOnDevice)
}
```

Register `CloudModels.jev` using the [Jev setup example](Models.md#jev).
A language model can answer the same questions through guided generation,
including as an available on-device fallback, without Jev's probabilities.

Decision models do not generate summaries or act as general-purpose agents.

[Policies →](ContextAndPolicies.md) · [Errors and limits →](ExecutionSafety.md) · [Review and resume →](Recovery.md)
