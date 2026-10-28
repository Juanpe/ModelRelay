---
name: modelrelay
description: Add, build, wire, review or test language-model workflows in an app that uses, or wants to add, the ModelRelay Swift package (github.com/Juanpe/ModelRelay). Use whenever code imports ModelRelay, ModelRelayHTTP, ModelRelayCloud, ModelRelayMCP or ModelRelayMLX, uses Workflow, Step, ModelCatalog or WorkflowExecutor, or the user wants multi-step AI features in Swift (extract, classify, decide, agents with tools, MCP, Jev, Ollama, Apple on-device models, approval and resume). Not for contributing to the ModelRelay repository itself; follow its AGENTS.md there.
---

# 🧩 ModelRelay in your app

ModelRelay composes language-model steps in Swift on top of AnyLanguageModel.
The app you are working in is the **host**: it owns the interface, accounts,
credentials, storage and sign-in. ModelRelay connects the steps.

Work in this order:

1. Add ModelRelay, if the app doesn't have it yet.
2. Find the version and its docs.
3. Pick products and steps.
4. Wire the executor.
5. Check the host rules.
6. Test without live models.

## 📲 1. Add ModelRelay

Skip this step when the step 2 lookup already finds a resolved version.
Adding a dependency is the user's call: confirm first unless they asked for
ModelRelay explicitly.

```sh
# Latest release
git ls-remote --tags --refs https://github.com/Juanpe/ModelRelay.git | sed 's|.*/||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
```

| The app uses… | Add it by |
| --- | --- |
| A `Package.swift` | Editing the manifest, then `swift package resolve` |
| An Xcode project | Asking the user to use File › Add Package Dependencies… with the URL, version rule and products below. Don't hand-edit `project.pbxproj` |
| XcodeGen or Tuist | Editing that manifest, then regenerating the project |

```swift
// Dependencies: up to the next minor while ModelRelay is pre-1.0.
.package(url: "https://github.com/Juanpe/ModelRelay.git", "0.1.0" ..< "0.2.0", traits: []),

// Target dependencies: only the products you use.
.product(name: "ModelRelay", package: "ModelRelay"),
```

- It needs Xcode 27 / Swift 6.4 and at least iOS 18, macOS 15 or visionOS 2.
  Raise the app's deployment target only with the user's agreement.
- Using OpenAI, Anthropic, Ollama or another native provider? Also add
  `AnyLanguageModel` at the exact version ModelRelay's `Package.swift` pins.
- Using MLX? Add `ModelRelayMLX`, change `traits: []` to `traits: ["MLX"]`
  and install the Metal Toolchain.
- Full setup: `README.md#installation` and `Documentation/Models.md#setup`.

Resolve packages, then continue with the fresh checkout in step 2.

## 📍 2. Find the version and its docs

The docs that match the app's resolved version always win over this skill
and over your memory. Read them before writing code.

```sh
# Resolved version (SwiftPM package or Xcode project)
find . -name Package.resolved -not -path "*/.build/*" -exec grep -i -A6 '"modelrelay"' {} +

# Local checkout of that version
ls -d .build/checkouts/ModelRelay ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/ModelRelay 2>/dev/null
```

- Several DerivedData folders? Pick the one named after this project and
  confirm with `git -C <checkout> describe --tags`.
- A `.package(path:)` dependency points straight at the checkout.
- No checkout yet? Resolve packages first (`swift package resolve` or open the
  project in Xcode), or read `https://github.com/Juanpe/ModelRelay/tree/<version>`.

Inside the checkout:

| Need | Read |
| --- | --- |
| Which API fits the task | [references/api-map.md](references/api-map.md), then the linked doc |
| Exact signatures | `Sources/ModelRelay*/`: grep `public`, never guess parameters |
| A runnable, model-free example | `Examples/StandaloneClient` |
| Workflow JSON shape | `Examples/workflows` |
| What changed between versions | `CHANGELOG.md` |

> 📣 If the app's version predates something in this skill, the checkout is
> right. Tell the user when a feature needs a newer ModelRelay release.

## 📦 3. Pick products and steps

| Product | Add it for |
| --- | --- |
| `ModelRelay` | Workflows, values, builders, execution, Apple built-in models |
| `ModelRelayHTTP` | `Step.request` and HTTP agent tools via `URLSessionRequestPerformer` |
| `ModelRelayCloud` | Typed decisions with Jev (`DecisionsAPIModel`) |
| `ModelRelayMCP` | MCP tools over Streamable HTTP and OAuth helpers |
| `ModelRelayMLX` | In-process MLX presets; also needs `traits: ["MLX"]` |

General cloud and local providers (OpenAI, Anthropic, Ollama, compatible
servers) are native AnyLanguageModel types. The app adds `AnyLanguageModel`
as its own dependency, at the version ModelRelay pins, and registers them.

Start from a minimal shape and grow it:

```swift
import ModelRelay

let workflow = Workflow(
    name: "Receipt to expense"
) {
    Step.extract("expense", instruction: "Extract the expense from this receipt.", model: .appleOnDevice) {
        Field("merchant", .text)
        Field("total", .number)
    }
}
let report = try await WorkflowExecutor().run(workflow, input: .text(receiptText))
```

Step names are how later steps reference results (`input: "expense"`,
`{{expense.total}}`). The full step and modifier map is in
[references/api-map.md](references/api-map.md).

## 🔌 4. Wire the executor

Build one `WorkflowExecutor` per configuration, with explicit dependencies:

| Executor input | Comes from |
| --- | --- |
| `catalog:` | `ModelCatalog().registering("id", location:) { nativeModel }` |
| `requests:` | `URLSessionRequestPerformer()` or the app's `RequestPerformer` |
| `secrets:` | The app's `SecretProvider`, backed by secure storage |
| `writePolicy:` | `.deny` (default), `.ask { request in … }` or `.allow` |
| `toolKits:` / `toolServers:` | `ToolKit`s and an `MCPConnector` |
| `hostToolKits:` | `HostToolKit`s: tools the app writes in Swift |
| `policy:` / `limits:` | `.localOnly`, `.readOnly`, `.noTools`; `WorkflowExecutionLimits` |

- `run` returns the report. `execute` adds live `updates`; keep the handle
  alive and add `defer { execution.cancel() }`.
- `start` / `resume` plus a `WorkflowExecutionCheckpointStore` handle human
  approval. Read `Documentation/Recovery.md#storage-contract-atomic-durable-compare-and-swap`
  before implementing a store.
- Call `await executor.validate(workflow)` to surface definition issues early.

## 🧭 5. Check the host rules

These come from the SDK's safety contracts. Breaking one is a bug, even when
it compiles. Details and fixes: [references/pitfalls.md](references/pitfalls.md).

1. **Credentials are request-only.** Use `{{secret.NAME}}` with a
   `SecretProvider`. Never put keys in prompts, templates, workflow JSON,
   logs or step names. Service keys belong on a backend.
2. **Writes are explicit.** Non-GET requests and non-read-only tools need a
   `WritePolicy`. They are never retried; a timeout does not prove a write failed.
3. **One fallback, no retry loops.** Each model step gets at most one
   `fallback:`. Do not wrap `run` in a retry loop.
4. **Never execute model output.** Templates only substitute values.
   `Step.custom` runs trusted, compiled Swift. Tool output is data, not authorization.
5. **Use native providers.** Register AnyLanguageModel `LanguageModel`s in the
   catalog. Do not write another provider abstraction or transcript bridge.
6. **Locality is declared, not guessed.** Only register `location: .local`
   when data provably stays on device. Ollama and other HTTP servers are `.remote`.
7. **Branch at runtime with steps.** Swift `if` inside a builder runs once at
   construction. Use `Step.ifEquals` or `Step.switchOn` for model-driven paths.
8. **Templates replace the prompt.** Any `{{…}}` marker makes the rendered
   instruction the whole prompt; include `{{input}}` when the model needs it.
9. **Gate availability.** The package supports iOS 18, macOS 15 and visionOS 2.
   Apple's on-device model needs OS 26; image input and Private Cloud Compute
   need OS 27. Configure a fallback or another provider for older systems.
10. **The host owns state.** UI, persistence, sign-in presentation, token
    refresh and checkpoint storage live in the app, not in workflow code.

## 🧪 6. Test without live models

Default tests should not need a model, network or key.

| Test | How |
| --- | --- |
| Definition and references | `executor.validate(workflow)`, `workflow.referenceIssues` |
| Data flow without models | `Step.template` and `Step.custom` |
| Model steps | A scripted AnyLanguageModel `LanguageModel` registered under the step's model ID |
| HTTP and tools | `URLSessionRequestPerformer(configuration:)` with a `URLProtocol` stub, or a fake `RequestPerformer` |
| Approval and resume | A test store that honors compare-and-swap, plus a fresh executor for `resume` |

The SDK's own scripted model is a good reference:
`Tests/ModelRelayTests/Support/ScriptedModel.swift` in the checkout. Copy the
idea into the app's tests; it is not a public product.

Keep live-model tests opt-in, behind an environment flag.
