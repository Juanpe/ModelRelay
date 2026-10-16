# Usage recipes

[← Back to the README](../README.md)

Start with the README's receipt example, then add the pieces your feature needs:

- [Step types](#step-types)
- [Composition](#composition)
- [Values and input](#values-and-input)
- [HTTP requests and agent tools](#http-requests-and-agent-tools)
- [Cloud models](#cloud-models)
- [Images](#images)
- [Custom Swift](#custom-swift)
- [MCP tools and OAuth](#mcp-tools-and-oauth)
- [Decision models](#decision-models)

## Step types

| Step | What it does |
| --- | --- |
| `prompt` | Generates text |
| `extract` | Returns typed fields through guided generation |
| `classify` | Chooses one label |
| `decide` | Answers typed questions together |
| `agent` | Lets a model call configured tools before answering |
| `readImage` | Reads an image with a vision model or on-device text recognition |
| `template` | Substitutes values without calling a model |
| `request` | Calls an HTTP API; a JSON response becomes typed values |
| `useTool` | Calls a named tool directly, without a model |
| `custom` | Runs a trusted, compiled Swift body |
| `ifEquals` / `switchOn` | Chooses a branch from a result |
| `parallel` | Runs independent children and collects their results |

Workflows are trees of steps, not manually wired graphs. Constructing a
workflow never calls a model or tool.

## Composition

Builders collect ordinary values. You can mix existing `Step` values,
arrays of steps and Swift `if`, `switch`, `for` or availability checks.
`Step.extract` also accepts existing fields through `FieldBuilder`.
Array-based initializers remain available.

Swift control flow inside a builder runs when you **build** the workflow.
To branch on a model's result during **execution**, use an explicit step:

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

For multiple paths, `Step.switchOn` accepts `[SwitchCase]`.
`SwitchCase("value") { ... }` builds a case; the trailing block of
`Step.switchOn` builds the default branch.

Builders are syntax sugar, not validators. Execution validates definitions
automatically; `await executor.validate(workflow)` gives diagnostics before
you run. `referenceIssues` remains available for reference-only checks.

## Values and input

`Value` supports text, numbers, booleans, lists, dictionaries and images.
Models receive structured values as JSON; text templates format them for people.

| To read… | Use… |
| --- | --- |
| The previous result | Leave the step's `input` unset |
| The original workflow input | `input: "input"` |
| A completed step | `input: "expense"` |
| One field | `input: "expense.total"` |
| A value inside text | `{{expense.total}}` |
| One result from a parallel block | `{{analysis.tone}}` or `{{tone}}` |

Parallel children receive the same incoming snapshot. They cannot read
each other's results. Their block returns a dictionary keyed by child name.

> If an instruction contains template markers, the rendered text is the
> **entire prompt**. Include `{{input}}` yourself if the model needs it.

`Workflow(name: "Name", output: "result")` returns that named step's whole value;
without `output`, execution returns the last result. Invalid explicit
outputs and missing references fail rather than silently returning another
value or substituting empty text.

Each execution owns its results and records. Reusing an executor does not
carry a conversation between unrelated executions. See [context and policies](ContextAndPolicies.md)
for shared native sessions and explicit handoffs between models.

`stepTimeout` defaults to 30 seconds per bounded operation, not per workflow.
A fallback has its own attempt. Cancellation and timeouts are cooperative;
they cannot override limits imposed by the caller or operating system.
For total-duration and call budgets, see [execution safety](ExecutionSafety.md).

## HTTP requests and agent tools

Add the `ModelRelayHTTP` product and supply a request performer:

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

Replace the example URL with your API before running it. The core has no
network implementation; you can supply your own `RequestPerformer` instead.

URL substitutions are percent-encoded. JSON substitutions are escaped for
their position: `"name": "{{expense.merchant}}"` inserts text, while
`"expense": {{expense}}` inserts a typed JSON value. A model result fills
the configured request; it does not become executable code.

Credentials come from a host-supplied `SecretProvider`, such as your
Keychain integration. `{{secret.NAME}}` is available only in request
templates and is hidden in request descriptions, not exposed to prompts.
Keep credentials out of workflow definitions.

Writes are denied by default. Supply `.allow` or `.ask { request in … }`
as the executor's `WritePolicy` when your host authorizes them.
The executor never retries HTTP requests or tool calls. A timeout still
cannot tell you whether a remote write succeeded.

To read a web page, use
`HTTPRequest(url: "{{input}}", reading: .page)`. It returns the title and
readable text, without page scripts, menus or markup. A whole-value URL
reference must resolve to an HTTP or HTTPS address.

### Give an agent an HTTP tool

The model fills typed parameters; the request reads them as `{{args.NAME}}`:

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

Run it with an executor configured with a request performer. Tools use the
same escaping, secrets and write policy as request steps. Agent steps have
a six-tool-call limit; after a tool is dispatched, an agent does not switch
to a fallback model. This is not an exactly-once delivery guarantee.

Group tools in a `ToolKit` to reuse them. Pass the kits to the executor and
select them with `kits: ["weather"]` on an agent step.

## Cloud models

Register AnyLanguageModel providers directly; no ModelRelay provider bridge
is needed:

```swift
import AnyLanguageModel
import Foundation
import ModelRelay

func makeCloudExecutor(baseURL: URL, modelName: String, apiKey: String) -> WorkflowExecutor {
    let model = OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: modelName)
    let catalog = ModelCatalog().registering("writer", location: .remote) { model }
    return WorkflowExecutor(catalog: catalog)
}

let workflow = Workflow(
    name: "Cloud summary"
) {
    Step.prompt("summary", "Summarize in three bullet points.", model: "writer")
}
```

Choose a server-supported model and pass credentials at runtime, never in
workflow JSON. For Anthropic, use
`AnthropicLanguageModel(apiKey: apiKey, model: modelName)`.

If you import providers directly, declare AnyLanguageModel and its product
in your client's SwiftPM dependencies too. Both packages resolve the same
AnyLanguageModel 1.0.0 dependency, not two copies.

AnyLanguageModel owns inference and native conversations. ModelRelay caches
model factories per active execution invocation; provider weight and KV-cache
management remains with the provider. [Resource lifetime details →](ContextAndPolicies.md#resource-lifetime)

## Images

`readImage` takes `Value.image` and returns text. An empty instruction asks
for all text as written; a vision-capable model can follow a specific request:

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

Register `claude` with `supportsImages: true` and a model that actually
supports vision. Native providers handle their API's image encoding.
The executor validates and normalizes the image before inference.

`.appleTextRecognition` uses on-device Vision and ignores the instruction.
That step keeps the image on the device; a later step still needs its own
privacy policy. First use prepares the recognition model; call
`TextRecognitionModel.prepare()` ahead of time to avoid the first-run delay.

An entry without image support fails before inference and can use its one
fallback. Step records describe the image, never storing its bytes.

## Custom Swift

Use a compiled body for logic that does not need a model:

```swift
import Foundation
import ModelRelay

let workflow = Workflow(
    name: "Normalize and summarize"
) {
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
```

The body is `@Sendable (CustomStepContext) async throws -> Value`.
It reads the previous output by default, or a selected `input:` reference.
`results` and the subscript expose completed results only. The body runs
once on its selected path, with step records and cooperative cancellation,
without fallback or automatic replay.

Custom bodies are trusted host code. `WritePolicy` does not sandbox them;
their context has no executor transports or secrets, but closures can
capture host resources. Blocking code cannot be forcibly stopped by a timeout.
Never use a body to evaluate model-generated source.

Workflow definitions containing bodies cannot be serialized, including
nested closures. Declarative workflows remain Codable. Reference renaming
cannot inspect keys hardcoded in a closure.

For recovery, rebuild the definition in Swift and restore its separate data
checkpoint. Change the host revision when bodies or captures change.
A host-owned code editor can invoke its own interpreter here; ModelRelay
does not choose or depend on that interpreter.

## MCP tools and OAuth

Add `ModelRelayMCP`. A kit with a server discovers its tools over Streamable
HTTP. Agents can use the kit; a `useTool` step calls one tool directly:

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

Tools not marked read-only are treated as writes and need authorization.
Tool calls are not retried by the executor.

For OAuth, `MCPConnector.accessToken` asks the host for the current token
when connecting. Use your own OAuth client, or the optional `MCPSignIn`
helpers for discovery, registration, PKCE, exchange and refresh.
Your host owns browser presentation, callback validation, secure token
storage and serialized refresh.

This is a tools connector, not a complete MCP SDK: its initial protocol is
`2025-06-18`; resources, prompts and stdio are not implemented. OAuth helpers
also have compatibility limits. Read the [authentication contract](Integration.md#mcp-and-oauth)
before integrating a server.

## Decision models

Need several typed answers rather than free-form text? A `decide` step can
ask yes/no, choice and score questions together:

```swift
import ModelRelay
import ModelRelayCloud

func makeDecisionExecutor(apiKey: String) -> WorkflowExecutor {
    let catalog = ModelCatalog().registering(decisions: "jev", location: .remote) {
        DecisionsAPIModel(apiKey: apiKey)
    }
    return WorkflowExecutor(catalog: catalog)
}

let workflow = Workflow(
    name: "Triage ticket"
) {
    Step.decide("ticket", questions: [
        Question("damaged", "Does the customer report a damaged item?", .yesNo),
        Question("team", "Which team should handle it?", .choice([.init("billing"), .init("shipping")])),
        Question("urgency", "How urgent is it?", .score(["low", "medium", "high"])),
    ], model: "jev", fallback: .appleOnDevice)
}
```

`DecisionsAPIModel` uses the specialized decisions API, including TypeSafe's
Jev through Vercel AI Gateway, and can return confidence information.
Language models answer the same questions through a guided schema; an
available on-device model can be the fallback.

Decision models answer typed questions. They do not generate summaries or
serve as general-purpose agents.

For execution policies, budgets, typed failures and approval checkpoints,
continue with [context and policies](ContextAndPolicies.md),
[execution safety](ExecutionSafety.md) and [recovery](Recovery.md).
