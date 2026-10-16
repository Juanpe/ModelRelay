# ⏸ Recovery and human review

[← README](../README.md) · [Execution safety](ExecutionSafety.md) · [Context](ContextAndPolicies.md)

Pause before a step, show the result to a person, then continue with a new
executor. Confirmed steps are not replayed.

[▶️ Start](#entry-points) · [👀 Review](#define-once-review-later) · [💾 Storage](#storage-contract-atomic-durable-compare-and-swap) · [🩺 Interruptions](#interrupted-operations-and-side-effects)

<a name="entry-points"></a>

## ▶️ Pick the right entry point

| API | Purpose |
| --- | --- |
| `start` | New `executionID`; saves initial state before work |
| `resume` | Continues that execution with fresh host integrations |
| `requiringApproval` | Pauses before a top-level step/block |
| `confirmCompletion` | Records an externally verified interrupted leaf without rerunning it |

For progress updates, use `startStream` / `resumeStream`; their `result`
returns the same outcome. See [streaming and cancellation](ExecutionSafety.md#metadata-only-execution-events).

Outcomes are `.completed(report)`, `.awaitingApproval(checkpoint)` or
`.rejected(checkpoint)`. Failures still throw. Ordinary `run` and nested
approval gates are rejected before work; gate the containing block instead.

A workflow is the definition. Each `start` creates a separate execution;
`resume` keeps the same identity. This is not a database, scheduler or
background-execution guarantee.

<a name="define-once-review-later"></a>

## 👀 Define once, review later

Keep a stable `workflowID`. These snippets assume your host has a configured
`executor`, durable `store` and incoming `message`:

```swift
let workflow = Workflow(
    name: "Draft and send",
    id: workflowID
) {
    Step.prompt("draft", "Write a concise support reply.", model: .appleOnDevice)
    Step.request("send", HTTPRequest(.post, url: "https://support.example/replies",
        headers: [.init("Authorization", "Bearer {{secret.API_KEY}}")],
        body: #"{"text":"{{draft}}"}"#))
        .requiringApproval("Review the reply before sending")
}

let outcome = try await executor.start(
    workflow, input: message, revision: "support-v1", store: store
)
```

When `outcome` is `.awaitingApproval(checkpoint)`, show
`checkpoint.results["draft"]`, `records`, `step` or `approval` in your UI.
After the person approves, resume with that latest checkpoint:

```swift
let outcome = try await executor.resume(
    workflow, from: checkpoint, revision: "support-v1",
    approval: .approve, store: store
)
```

- Approval covers the current gate only; `.reject` is terminal.
- No decision returns the pending approval without loading models, secrets or tools.
- Tightened limits can create a newer generation; never approve a stale snapshot.
- Configure transport, secrets and `WritePolicy` on the executor.

> 📣 Approval does not override write/privacy policy. Gating an agent approves
> entering that step, not every future tool call. Use `WritePolicy.ask` for
> live write decisions; it is not a durable pause inside an agent's tool loop.

<a name="storage-contract-atomic-durable-compare-and-swap"></a>

## 💾 Make saves atomic and durable

Implement `WorkflowExecutionCheckpointStore.save(_:replacing:)`:

| `replacing` | Required operation |
| --- | --- |
| `nil` | Create by `executionID` only if absent |
| A generation | Replace only if the stored generation matches |
| Mismatch | Throw `RecoveryError.checkpointConflict` |

Commit the whole checkpoint atomically and durably **before returning**.
Coordinate every worker/device that can resume that execution. An in-memory
actor or unconditional overwrite does not satisfy this contract.

The executor saves a `running` claim before a top-level operation and confirms
the state afterward. Competing resumes race for that claim; only one may win.
It also saves approval and terminal boundaries.

> ⚠️ A streamed step record is not a commit receipt. If saving throws, reload the
> latest stored checkpoint: commit may have succeeded without acknowledgement.
> Never overwrite a newer generation with an older snapshot.

Starting again creates a different execution. Deduplicating incoming jobs
belongs to the host.

<a name="what-is-restored"></a>

## 📦 Know what a checkpoint contains

| Restored | Recreated by your host/provider |
| --- | --- |
| Input, confirmed results and previous value | Credentials and authorization callbacks |
| Privacy labels, policy and step records | Model weights / KV caches |
| Native named conversation transcripts | Open MCP connections |
| Schema 2 limits, usage and accumulated active duration | Compiled custom bodies |

Resume only narrows policy/limits; it cannot relax the saved ceiling.
Review time between invocations is excluded. For interrupted duration-limited
work, `confirmCompletion` requires `elapsed:`.
[Budget accounting →](ExecutionSafety.md#global-limits-and-usage)

History returns to its original conversation name and model ID. Current tools,
resolvers and budgets are rebound; restoring old tool history does not call
those tools. Changed models, stale opaque metadata or large histories may be
rejected by the provider. There is no automatic compaction or cross-provider
transcript translation.

<a name="definition-identity-and-compiled-custom-bodies"></a>

## 🪪 Keep identity stable

A definition digest checks step order, instructions, models, context, policies,
gates and tool-kit configuration. Recovery also requires the same nonempty
host revision and workflow UUID.

The digest sees custom-step shape, not executable closures or captured objects.
Rebuild those bodies in Swift and bump the revision when code, captures,
model configuration, credentials/account binding or executable dependencies change.
The workflow definition itself remains non-serializable if it has closures.

> 🔒 The digest detects changes; it is not authentication. Accept only trusted
> checkpoints bound to the right account, workflow and deployment. Client-edited
> JSON must not authorize skipping review, weakening labels or inventing results.

Schema 2 does not migrate earlier development checkpoint shapes or identity
aliases. See [migration notes](NativeRuntimeMigration.md).

<a name="interrupted-operations-and-side-effects"></a>

## 🩺 Reconcile before continuing

| Stored status | Safe next action |
| --- | --- |
| `ready` | Resume the next top-level step |
| `awaitingApproval` | Review, then approve/reject |
| `running` | Stop/fence the worker and reconcile externally |
| `completed` | Read the report without executing steps |
| `rejected` | No continuation |

A remote write may succeed before its result is saved. Timeout, cancellation
or transport failure cannot distinguish that from a request that never arrived.
Even apparently harmless failures leave `running`; `resume` throws
`RecoveryError.interrupted(step:)` before invoking code.

1. **Stop/fence the old worker.** A `running` marker does not prove it died;
   compare-and-swap does not cancel an active body or remote request.
2. **Verify the result externally.** Use a service's idempotency key or
   queryable business operation ID where available.
3. **Confirm only a supported leaf.** Request, named tool, template or custom
   steps can use `confirmCompletion` with a verified value and required elapsed time.

Confirmation marks the record `recovered`, preserves privacy restrictions
and advances without calling the operation. It does not query the service.
Blocks and model/agent steps need child results or native history, so one
value cannot reconcile them; handle termination/reconciliation in the host.

Recovery boundaries are top-level steps. An interrupted branch/parallel block
cannot resume from a child; completed child writes are not automatically replayed.

<a name="sensitive-data-and-scope"></a>

## 🔒 Protect the stored state

Checkpoints omit executor credentials, prepared requests, executable bodies
and tool closures. They can contain user input, images, model/tool output,
transcripts and echoed sensitive data.

Encrypt/restrict access, bind accounts, set retention and honor local-only
restrictions when choosing storage. The store is trusted host code, not
sandboxed by the executor. Never put API keys in workflow literals.

There is no exactly-once guarantee, automatic replay, distributed queue or
durable token stream. The host decides when another worker may resume.
Offline tests cover restoration, claims, policies and lost acknowledgements,
not your production store's durability or live-provider availability.
