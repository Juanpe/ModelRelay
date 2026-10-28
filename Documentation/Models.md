# 🧠 Models and providers

[← README](../README.md#models) · [Usage recipes](Usage.md) · [Context and policies](ContextAndPolicies.md)

Register a provider once, then use its catalog ID in a step. `"writer"` is
your workflow's name for a model, not the provider's model identifier.

[🦙 Ollama](#ollama) · [🗳 Jev](#jev) · [☁️ Cloud](#cloud) · [🔌 Servers](#compatible-servers) · [🍎 Apple](#apple) · [⚡️ MLX](#mlx) · [🔀 Mix models](#mix-models)

<a name="setup"></a>

## 📦 Add the products you use

Clients that import native providers declare AnyLanguageModel directly.
SwiftPM shares the same dependency ModelRelay uses, not a second copy:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MyClient",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    dependencies: [
        .package(url: "https://github.com/Juanpe/ModelRelay.git", "0.2.0" ..< "0.3.0", traits: []),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", exact: "1.0.0", traits: []),
    ],
    targets: [
        .target(name: "MyClient", dependencies: [
            .product(name: "ModelRelay", package: "ModelRelay"),
            .product(name: "ModelRelayCloud", package: "ModelRelay"),
            .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
        ]),
    ]
)
```

`ModelRelayCloud` is only needed for specialized decisions such as Jev.
Apple's built-ins need only `ModelRelay`; MLX has a separate opt-in below.
Release availability and development-branch setup are in the
[installation guide](../README.md#installation).

> 🔒 Pass credentials at runtime, never through workflow JSON or prompts.
> Keep your service keys on a backend, not bundled in a distributed app.
> A bring-your-own-key app should use only its user's credentials from secure
> storage. [OpenAI's credential guidance →](https://developers.openai.com/api/reference/overview#authentication)

<a name="ollama"></a>

## 🦙 Summarize with Ollama

[Install and start Ollama](https://docs.ollama.com/quickstart), then download
the example model, [Qwen 3 0.6B](https://ollama.com/library/qwen3:0.6b):

```sh
ollama pull qwen3:0.6b
```

With Ollama running on your Mac:

```swift
import AnyLanguageModel
import ModelRelay

let model = OllamaLanguageModel(model: "qwen3:0.6b")
let catalog = ModelCatalog().registering("ollama", location: .remote) { model }
let workflow = Workflow(
    name: "Summarize article"
) {
    Step.prompt("summary", "Summarize in three short bullet points.", model: "ollama")
}
let executor = WorkflowExecutor(catalog: catalog)
let report = try await executor.run(workflow, input: .text("Your article text"))
print(report.output.textValue)
```

The native provider uses `http://localhost:11434/api/chat`. For another
server, pass `baseURL:` with its origin, without `/v1` or `/api/chat`.
The first request may load weights; adjust `stepTimeout` if needed.

> 📱 On a physical iPhone or iPad, `localhost` means that device, not your Mac.
> Use a reachable, secured server. Your host owns network permissions,
> transport-security configuration and any required sandbox entitlements.

Network examples use `.remote`, including Ollama: inference runs on the
server you connect to. Only mark a model `.local` when you have verified
that data stays on-device. [Privacy contract →](ContextAndPolicies.md#execution-policies)

<a name="jev"></a>

## 🗳 Make typed decisions with Jev

Jev is a decision model, not a chatbot. Use it for yes/no questions, choices
and scores. ModelRelay's `DecisionsAPIModel` uses Vercel AI Gateway's
OpenAI-compatible `/v1/decisions` route with `typesafe-ai/jev`.
Pass an **AI Gateway key**, not a direct TypeSafe or OpenAI key.
[Gateway integration →](https://vercel.com/i/jev-integrations)

```swift
import ModelRelay
import ModelRelayCloud

func triageTicket(_ text: String, gatewayKey: String) async throws -> WorkflowExecutionReport {
    let catalog = ModelCatalog().registering(decisions: CloudModels.jev, location: .remote) {
        DecisionsAPIModel(apiKey: gatewayKey)
    }
    let workflow = Workflow(
        name: "Triage ticket"
    ) {
        Step.decide("ticket", questions: [
            Question("urgent", "Does this need attention today?", .yesNo),
            Question("team", "Which team should handle it?", .choice([
                .init("billing"), .init("technical"), .init("review"),
            ])),
            Question("priority", "How urgent is it?", .score(["low", "medium", "high"])),
        ], model: CloudModels.jev)
    }
    return try await WorkflowExecutor(catalog: catalog).run(workflow, input: .text(text))
}
```

`CloudModels.jev` is a predefined catalog ID, like the IDs in `MLXModels`.
Provider setup stays explicit; custom aliases such as `"triage"` work too.

Pass `session:` to `DecisionsAPIModel` to share an HTTP session or supply a test
transport. Otherwise, each model reuses its own ephemeral session.

Read the answers from `report.output["urgent"]`, `["team"]` and `["priority"]`.
Provider confidence lives under `["confidence"]`; numeric scores under
`["scores"]`. For yes/no, confidence is the probability of **yes**, not
certainty in the returned Boolean. Do not treat it like choice confidence.

Jev works with `decide` and `classify`, not `prompt`, `extract` or `agent`.
A registered language model can answer the same questions as an explicit
fallback, without Jev's probabilities. [Typed-question recipe →](Usage.md#decision-models)

<a name="cloud"></a>

## ☁️ Use OpenAI or Anthropic

Choose provider model IDs available to your account. These helpers register
them as `"openai"` and `"claude"`:

```swift
import AnyLanguageModel
import Foundation
import ModelRelay

func makeCloudExecutor(openAIKey: String, openAIModel: String,
                       anthropicKey: String, anthropicModel: String) -> WorkflowExecutor {
    let openAI = OpenResponsesLanguageModel(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        apiKey: openAIKey, model: openAIModel
    )
    let claude = AnthropicLanguageModel(apiKey: anthropicKey, model: anthropicModel)
    let catalog = ModelCatalog()
        .registering("openai", location: .remote) { openAI }
        .registering("claude", location: .remote) { claude }
    return WorkflowExecutor(catalog: catalog)
}
```

Use either ID in `Step.prompt`, `Step.extract` or a tool-enabled `Step.agent`.
The provider and selected model must support the requested capability;
register `supportsImages: true` only for an actual vision model.
AnyLanguageModel owns the native requests and sessions.

<a name="compatible-servers"></a>

## 🔌 Bring an OpenAI-compatible endpoint

For servers exposing `/chat/completions`, use `OpenAILanguageModel` instead
of the Responses provider. Include the API prefix in `baseURL`, such as `/v1`:

```swift
import AnyLanguageModel
import Foundation
import ModelRelay

func makeCompatibleExecutor(baseURL: URL, modelName: String, apiKey: String) -> WorkflowExecutor {
    let model = OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: modelName)
    return WorkflowExecutor(catalog: ModelCatalog().registering("writer", location: .remote) { model })
}
```

Select `model: "writer"` in your step. No provider wrapper is needed.
Other native AnyLanguageModel providers register the same way.

<a name="apple"></a>

## 🍎 Use Apple's built-in models

No registration or API key needed:

```swift
import ModelRelay

let workflow = Workflow(
    name: "On-device summary"
) {
    Step.prompt("summary", "Summarize in one sentence.", model: .appleOnDevice)
}
let report = try await WorkflowExecutor().run(workflow, input: .text("Your article text"))
```

| ID | Use |
| --- | --- |
| `.appleOnDevice` | On-device generation and tools, on OS 26+ |
| `.applePrivateCloud` | Private Cloud Compute, on OS 27+ with its entitlement |
| `.appleTextRecognition` | Local Vision OCR in `readImage`, on all supported OS versions |

Apple Intelligence still needs compatible hardware and ready models.
OS-unavailable built-ins report `.modelUnavailable`; a configured fallback
can run if policy permits. [Platform requirements →](../README.md#installation)

<a name="mlx"></a>

## ⚡️ Run a model in-process with MLX

Add the `ModelRelayMLX` product and enable `traits: ["MLX"]` on ModelRelay.
ModelRelay forwards the trait to AnyLanguageModel for you.
[Installation and Metal Toolchain →](../README.md#installation)

```swift
import ModelRelay
import ModelRelayMLX

let catalog = ModelCatalog().registeringMLXModels()
let workflow = Workflow(
    name: "Local summary"
) {
    Step.prompt("summary", "Summarize in one sentence.", model: MLXModels.qwen3_0_6B)
}
let report = try await WorkflowExecutor(catalog: catalog).run(workflow, input: .text("Your article text"))
```

Presets load lazily through AnyLanguageModel; weights may download on first
use. Inference needs supported hardware and enough memory. Unlike Ollama,
this does not require a separate HTTP server.

<a name="mix-models"></a>

## 🔀 Mix Jev and Ollama in one workflow

Register both, then choose a different ID per step:

```swift
import AnyLanguageModel
import Foundation
import ModelRelay
import ModelRelayCloud

func makeMixedExecutor(gatewayKey: String, ollamaURL: URL) -> WorkflowExecutor {
    let writer = OllamaLanguageModel(baseURL: ollamaURL, model: "qwen3:0.6b")
    let catalog = ModelCatalog()
        .registering(decisions: "triage", location: .remote) { DecisionsAPIModel(apiKey: gatewayKey) }
        .registering("writer", location: .remote) { writer }
    return WorkflowExecutor(catalog: catalog)
}

let workflow = Workflow(
    name: "Triage and draft",
    output: "reply"
) {
    Step.decide("ticket", questions: [
        Question("team", "Which team should handle it?", .choice([.init("billing"), .init("technical")])),
    ], model: "triage")
    Step.prompt("reply", "Draft a brief acknowledgement for {{input}}. Team: {{ticket.team}}.", model: "writer")
}
```

Run it with the executor returned by `makeMixedExecutor`. Jev's selected
team becomes input to the writer; nothing is sent to a customer automatically.
Shared native conversations require the same model ID. To pass selected data
to another agent, use [handoff](ContextAndPolicies.md#three-context-modes).
