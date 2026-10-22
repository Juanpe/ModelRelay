# ⚠️ Pitfalls in host apps

Each row is a mistake agents tend to make, why it breaks a ModelRelay
contract, and what to write instead. Paths are relative to the checkout.

## 🔒 Credentials and writes

| Avoid | Why | Instead |
| --- | --- | --- |
| An API key inside an instruction, template or `HTTPRequest` literal | It reaches the model, records or workflow JSON | `{{secret.NAME}}` plus a `SecretProvider` reading secure storage |
| A provider key bundled in a distributed app | Anyone can extract it | Keep service keys on a backend; bring-your-own-key apps use the user's key |
| `writePolicy: .allow` to make a POST "just work" | Every write runs without review | `.ask { request in … }` with UI, or `.requiringApproval` on the step |
| Retrying a failed request, tool or `run` | Writes may already have happened | Surface the failure; reconcile with `Documentation/Recovery.md#interrupted-operations-and-side-effects` |
| Treating a timeout as "nothing was written" | The outcome is uncertain | Check `failure.info.outcomeUncertain` and verify externally |

## 🧠 Models and context

| Avoid | Why | Instead |
| --- | --- | --- |
| A custom wrapper protocol around providers | Duplicates AnyLanguageModel | Register the native `LanguageModel` in `ModelCatalog` |
| Two or more fallbacks, or a fallback chain | Only one fallback per step exists | Pick the best single `fallback:`; handle the rest in the app |
| `location: .local` for Ollama or a LAN server | Breaks `.localOnly` guarantees | `.remote` for anything reached over the network |
| Expecting history across `run` calls | Executions are isolated | `.conversation` within one execution; app-owned memory across runs |
| Sharing a conversation between parallel children | Not supported; the executor fails the workflow | Separate conversation names or a `.handoff` |
| Using Jev with `prompt`, `extract` or `agent` | Jev only answers typed questions | `Step.decide` or `Step.classify` |

## 🧩 Workflow definitions

| Avoid | Why | Instead |
| --- | --- | --- |
| Swift `if` on a model result inside the builder | It runs at construction time | `Step.ifEquals` or `Step.switchOn` |
| `"Summarize {{input}}"` thinking text is appended | Markers make the rendered text the whole prompt | Write the full prompt, including `{{input}}` |
| Evaluating model-generated code or expressions | The SDK never executes model output | `Step.custom` with compiled Swift that reads values |
| Encoding a workflow with `Step.custom` to JSON | Closures are not serializable | Rebuild it in Swift; bump the host `revision` when bodies change |
| Building approval with ad hoc flags | Loses durable review semantics | `start` / `resume` with a compare-and-swap checkpoint store |
| An in-memory store in production | Not durable or atomic across devices | A real store following `Documentation/Recovery.md#storage-contract-atomic-durable-compare-and-swap` |

## 📡 Observing and testing

| Avoid | Why | Instead |
| --- | --- | --- |
| Dropping the `WorkflowExecution` handle while reading updates | Releasing it cancels execution | Keep it alive; `defer { execution.cancel() }` |
| Logging `failure.rootCause` or raw step records | May contain user data or echoed secrets | Log `failure.info` and event metadata |
| Tests that call real providers by default | Flaky and needs keys | Scripted `LanguageModel` and a `URLProtocol` stub; live tests opt-in |
| Calling `.appleOnDevice` without an availability plan | Unavailable before OS 26 or without Apple Intelligence | A configured `fallback:` or another registered provider |
