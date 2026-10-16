# Recoverable executions and approval gates

ModelRelay can pause a logical execution, return its state to the host, and
resume in a new executor without replaying confirmed steps. This is an opt-in
execution API, not a background service, database or exactly-once guarantee.

## Entry points

- `start` creates a new execution ID and saves
  its initial checkpoint before doing work.
- `resume` continues that logical
  run. A new executor can supply fresh credentials, transports and model factories.
- `Step.requiringApproval(_:)` pauses **before** a top-level step or block.
  It does not suspend a task while waiting for a person.
- `confirmCompletion` lets the host
  supply the verified result of an interrupted request, tool call, template
  or custom leaf without rerunning it.

`WorkflowExecutionOutcome` is either `.completed(WorkflowExecutionReport)`,
`.awaitingApproval(WorkflowExecutionCheckpoint)` or
`.rejected(WorkflowExecutionCheckpoint)`. Failures still throw. Approval gates
used with ordinary `run` throw before any steps run; they are never silently ignored.
Only top-level gates are supported. A nested gate is rejected before work
or checkpoint creation; put the gate on the containing block instead.

`Workflow` is the reusable definition, not its execution state. Separate calls
to `start` have different `executionID`s even when they share a `workflowID`.
Resuming keeps the same execution identity. Checkpoint JSON uses `executionID`;
the earlier development-only identity key is not accepted as an alias. There
are no compatibility typealiases for the previous API names.

## Define once, review later

```swift
import Foundation
import ModelRelay

func reviewWorkflow(id: UUID) -> Workflow {
    Workflow("Draft and send", id: id) {
        Step.prompt("draft", "Write a concise support reply.", model: .appleOnDevice)
        Step.request("send", HTTPRequest(.post, url: "https://support.example/replies",
            headers: [.init("Authorization", "Bearer {{secret.API_KEY}}")],
            body: #"{"text":"{{draft}}"}"#))
            .requiringApproval("Review the reply before sending")
    }
}

func beginReview(id: UUID, message: Value, executor: WorkflowExecutor,
                 store: any WorkflowExecutionCheckpointStore) async throws -> WorkflowExecutionOutcome {
    try await executor.start(reviewWorkflow(id: id), input: message,
                           revision: "support-v1", store: store)
}

func finishReview(id: UUID, checkpoint: WorkflowExecutionCheckpoint,
                  decision: ApprovalDecision, executor: WorkflowExecutor,
                  store: any WorkflowExecutionCheckpointStore) async throws -> WorkflowExecutionOutcome {
    try await executor.resume(reviewWorkflow(id: id), from: checkpoint,
                            revision: "support-v1", approval: decision, store: store)
}
```

The host supplies storage, transport, secrets and an appropriate `WritePolicy`
on the executor. It can show `checkpoint.results["draft"]`, `records`, `step`
and `approval` in its own UI. `.approve` authorizes only the current checkpoint's
gate; another gate needs another decision. `.reject` is terminal. An approval
does **not** override `WritePolicy`, `.readOnly`, `.noTools` or `.localOnly`.
Agent gates authorize entering the whole step, not each future model-selected
tool request. Use `WritePolicy.ask` for individual live write approvals; that
closure is not a durable pause inside an agent's tool loop.

Calling `resume` without a decision on an approval checkpoint simply returns
the pending approval. It does not call a model, resolve secrets or make a request.
Use the latest checkpoint when applying a decision; stale decisions cannot
claim a step if the store enforces its contract.

## Storage contract: atomic, durable compare-and-swap

Implement `WorkflowExecutionCheckpointStore.save(_:replacing:)` in the host. There is no
filesystem/database implementation or storage dependency in the core.

1. With `replacing: nil`, create a record keyed by `checkpoint.executionID` only
   if it does not exist.
2. Otherwise, replace it **only** if the stored generation equals the
   supplied generation. If it differs, throw `RecoveryError.checkpointConflict`.
3. Commit the complete new checkpoint atomically and durably **before returning**.

A transactional database conditional update or an equivalent durable CAS
operation is required. An actor with an unconditional write is insufficient;
an in-memory actor serializes tasks but does not survive process termination.
Production stores must coordinate across all workers/devices that may resume
the same run, not just one executor instance.

ModelRelay saves a `running` claim before invoking a top-level step and saves
the complete state after it succeeds. Two simultaneous resumes of the same
checkpoint compete for that claim; only one may succeed. It also saves at
approval and terminal boundaries. `onStep` is a live execution observer,
**not** a durable-commit notification: it fires before the post-step save.

After a save throws, reload the latest state from the host store: the save
may have committed but its acknowledgement been lost. Never restore an old
snapshot over a newer generation. Calling `start` again creates a different
run, not an idempotent resume; deduplicating incoming jobs is host-owned.

## What is restored

Checkpoints are `Codable` and contain input, confirmed named values, privacy
labels, previous value, step records, active execution policy, accumulated
execution duration and named native conversation transcripts. Review time
between invocations is not part of that duration. Model resources/weights,
KV caches, open MCP connections and authorization callbacks are not serialized.
Model factories load lazily again on resume.

Schema 2 checkpoints also retain `WorkflowExecutionLimits` and confirmed
`WorkflowExecutionUsage`. The old development snapshot shape is not migrated.
Ceilings cannot be expanded on resume. For duration-limited leaf reconciliation,
the host must supply `elapsed:` for the interrupted attempt; otherwise confirmation
fails instead of silently dropping consumed time. See [ExecutionSafety](ExecutionSafety.md).

Native histories are restored only to their original conversation name and
model ID, including provider-specific metadata. A new model ID or fallback
has a separate lane; no cross-provider transcript translation is attempted.
Current tools, value resolvers, write permission and call budgets are rebound
for the new step. Restoring tool-call history does **not** execute those calls.
The provider must support the restored transcript; it may reject stale opaque
metadata, changed model versions or an oversized history. Compaction is not
implemented. Do not silently move such a transcript to a different provider.

The original execution policy cannot be relaxed by a new executor/run policy;
new restrictions can narrow it. Value and conversation privacy labels survive
JSON encoding and resumption. The new executor's catalog metadata and write
policy still apply before new operations.

## Definition identity and compiled custom bodies

Keep the workflow UUID stable. A definition digest detects changed step order,
instructions, models, context, policies, approvals and configured tool-kit data.
Recovery also requires the same **nonempty host revision**.

Custom bodies remain compiled, in-memory Swift closures. Encoding a workflow
containing them still throws. The host can reconstruct the workflow in Swift
and restore only its serializable execution state. The digest binds custom-step
positions/shape, not executable closure contents or captured objects. Bump the
host revision whenever a body, capture, model configuration behind an ID,
credential/account binding or other executable dependency changes. ModelRelay
cannot detect those changes by inspecting code or factory closures.

The digest is a change detector, **not authentication**. Load only trusted
checkpoints bound by the host to the right account, workflow and deployment.
Do not accept client-edited checkpoint JSON as authority to skip approval,
weaken privacy labels or inject completed results.

## Interrupted operations and side effects

| Stored status | Meaning | Safe next action |
| --- | --- | --- |
| `ready` | Previous top-level steps are confirmed | Resume at the next step |
| `awaitingApproval` | Current step has not started | Review and approve/reject |
| `running` | Current step may have partially or fully run | Reconcile externally; never automatic replay |
| `completed` | Final state is confirmed | Read the report without executing steps |
| `rejected` | The approval was rejected | No continuation |

A crash can occur after a remote write succeeds and before its result is
saved. Timeout, cancellation and transport errors cannot distinguish that
from a request that never reached the server. Even failures that look harmless
leave a conservative `running` marker; `resume` throws
`RecoveryError.interrupted(step:)` before loading a model or running any code.

Before reconciliation, the host must stop/fence the original worker and ensure
it cannot continue executing tools. Merely seeing `running` does not prove
that a worker has died; CAS does not cancel an already executing body or remote
request. Do not manually confirm a step while its original worker is active.

After independently verifying an interrupted leaf's remote/host result, call
`confirmCompletion` with that result. It saves the value, marks its record
`recovered`, preserves the step's privacy restrictions (and any stricter label
the host supplies), and advances without invoking the operation. It does not
query the remote service for you. Blocks and model/agent steps cannot be
reconciled with one value: their child results or native transcript would be
missing. Those runs require host-level reconciliation/termination instead.

Recovery boundaries are currently **top-level steps**. A conditional or
parallel block is one unit: a fully confirmed block is skipped on resume,
but interruption inside it cannot resume from an individual child. Completed
child side effects within an interrupted block are not automatically replayed.
This is deliberately more conservative than pretending the block is atomic
at the remote services.

For writes, use a service-supported idempotency key or independently queryable
business operation ID where possible. The host can pass that stable ID through
workflow input/templates; ModelRelay does not invent protocol-specific keys,
assume all services support them, or promise exactly-once remote execution.

## Sensitive data and scope

The checkpoint does not contain executor secrets, prepared requests, credentials,
compiled code or tool closures. It **does** contain potentially sensitive user
input, model responses, tool outputs, images and native transcript metadata.
A server/model can echo sensitive values in its output; there is no automatic
DLP or redaction guarantee for arbitrary data. Encrypt/restrict access, bind
the correct account, set retention and honor `.localOnly` when choosing storage.
The store itself is trusted host code, not sandboxed or network-policed by
ModelRelay. Provider API keys must never be embedded in workflow literals.

There is no scheduler, durable token-stream continuation, live OS background
execution guarantee, distributed job queue, automatic retry, MCP session pool
or token/cost budget in this feature. An OS interruption still ends the current
invocation; the host decides when another worker may resume.

The offline tests cover JSON restoration with a new executor, custom-body
reconstruction, native tool/Anthropic reasoning history, no secret capture,
policy retention, duplicate claims, approval/rejection and save failures both
before commit and after acknowledgement loss. They do not establish the
durability of a host's production store or a real provider's availability.
