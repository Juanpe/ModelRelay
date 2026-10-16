# Validation, failures, events and execution limits

These features apply to ordinary `run` and recoverable `start`/`resume`.
They do not introduce another inference runtime, storage backend or UI layer.

## Validation before execution

`await executor.validate(workflow)` returns `[WorkflowValidationIssue]` without
invoking model factories, requesting credentials or discovering remote tools.
Use it for editor/CLI diagnostics. Execution entry points automatically reject
invalid definitions, so calling it yourself is optional.

Checks cover schema version, unique/unreserved step names, available references,
explicit output, registered models (including fallback), compatible model
capabilities, field/label/question schemas and locally configured tool names.
Every branch is validated, including branches that will not be selected.
A compatible fallback is allowed when the primary lacks a capability.
`WorkflowValidationError.issues` holds aggregate diagnostics; context/approval
guards also retain their dedicated `RelayError`/`RecoveryError` cases.

Dynamic HTTP/MCP/custom response fields, remote tool discovery, model readiness
and actual credentials cannot be proven from the definition. Missing fields
are checked at execution before substituting/sending them; they no longer
silently become empty strings or JSON null. Use explicit `Value.null` for null.
An invalid explicit `Workflow.output` never silently returns the last result.
Models can still return unexpected values, and custom code is not inspected.

## Structured failures and retained causes

Operational failures use `RelayError.operationFailed(step:failure:)`:

```swift
do {
    _ = try await executor.run(workflow, input: input)
} catch RelayError.operationFailed(let step, let failure) {
    switch failure.info.category {
    case .authenticationRequired:
        // The host can initiate its own sign-in flow. Do not replay prior writes.
        break
    case .permissionDenied:
        break
    default:
        print(step, failure.info.message)
    }
    // Explicit, in-memory access for typed handling:
    // failure.rootCause as? MCPError / CloudModelError / HTTPResponseFailure
}
```

`WorkflowFailureInfo` is a serializable summary with a category, message and
`outcomeUncertain`. `WorkflowOperationFailure.underlyingError` retains the cause;
`rootCause` unwraps native tool/executor wrappers. Raw causes are **not Codable**
and never enter checkpoints or execution events. Failure equality compares
summary information, not identity of arbitrary underlying errors.

HTTP request failures expose `HTTPResponseFailure.status`; MCP and specialized
decision integrations classify their own typed errors. Host integrations can
conform errors to `WorkflowFailureClassifiable`. Native generation errors are
classified where their public types allow it. Some AnyLanguageModel 1.0 HTTP
errors have no public typed status; they remain `.unknown`, not guessed from
message text. The original cause is still retained.

Configured request credentials, including URL-encoded/JSON-escaped forms, are
redacted from request descriptions and failure summaries. Other provider/host
messages may contain sensitive data; summaries/`StepRecord`s are not anonymous
telemetry. Raw `rootCause` can contain a server-echoed credential: only inspect
it deliberately, never dump it into logs or persistence.

Dispatched writes are marked uncertain on failure, including an agent that
successfully calls a write tool and then fails to produce its final answer.
Custom bodies are also conservatively treated as potentially effectful.
Cancellation, policy denials and exhausted limits remain control flow, not a
reason to invoke a fallback. A cancellation/deadline can interrupt a write too;
absence of an operational failure wrapper does not prove nothing happened.

## Metadata-only execution events

Pass `onEvent:` to `run`, `start` or `resume`. `onStep:` remains available and
continues to expose full records, including values/input when present.

Events cover execution/step/model/tool lifecycle, fallback selection, approval,
successful checkpoint saves and exhausted limits. They contain IDs, declared
step/model/tool names, a failure category or checkpoint generation where relevant.
There are **no prompts, results, arguments, URLs, raw errors or credentials** in
the event type. Names are host-defined and can themselves be sensitive.

Callbacks are synchronous, `@Sendable`, serialized in sequence order within an
invocation and not main-actor isolated. Keep them short; dispatch UI work to
your own actor. Blocking observers also delay execution/cancellation. Their
retained references are released at completion, failure or pause.

`executionID` correlates one logical run; a new resume has a new `invocationID`
and restarts `sequence`. Correlate all three rather than expecting a globally
durable sequence. Validation rejection occurs before execution begins and
therefore does not emit execution events.

`checkpointSaved` is emitted **after** a successful durable store callback.
`onStep` completion still occurs before that save. Events are not a durable
event journal: a process can die after commit but before notification. A store
can commit and lose its acknowledgement; reload its latest checkpoint.
This is a callback API, not token streaming or a background execution service.

## Global limits and usage

```swift
let executor = WorkflowExecutor(limits: .init(
    maxDuration: .seconds(60),
    maxModelCalls: 8,
    maxToolCalls: 12,
    maxConcurrentSteps: 2
))
let report = try await executor.run(workflow, input: input,
    onEvent: { event in print(event.kind.rawValue, event.step ?? "") })
print(report.usage.modelCalls, report.usage.toolCalls)
```

Defaults are unlimited. Counts/duration may be zero; concurrency must be positive.
Negative values/zero concurrency throw `RelayError.invalidLimits` before work.
Per-invocation `limits:` can narrow the executor's ceiling, never expand it.

- `maxModelCalls` counts executor-mediated native session/decision attempts,
  including fallback and factory preparation. It does **not** count each opaque
  provider-internal HTTP/tool-continuation round inside a native response.
- `maxToolCalls` counts attempts admitted to HTTP/MCP tools and direct request
  steps, including attempts subsequently denied by write approval or failing
  preparation. Policy-denied calls are rejected first. Discovery/auth/listing
  requests are not tool invocations and are not charged as tool calls.
- `maxConcurrentSteps` limits leaf-step bodies across nested parallel blocks.
  Blocks hold no slot, avoiding nested deadlock. It does not separately limit
  parallel tool calls a native provider may make inside a single agent step.
- `maxDuration` bounds active invocation time, including provider preparation,
  requests, callbacks and store operations, using cooperative cancellation.
  Custom code/providers/stores must honor cancellation; nothing forcibly kills
  a blocking closure or extends OS deadlines. It is not a CPU/billing quota.

Reservations are atomic across parallel branches. Reaching a limit throws
`RelayError.limitExceeded`; it never activates model fallback. Independent
executions have independent counters, even on the same executor.

Recoverable checkpoints (schema **2**) retain effective limits, confirmed call
counters and accumulated active duration. Resume can only narrow those limits;
review time between invocations is excluded. Narrowing while still awaiting
approval saves a new generation, invalidating stale approval decisions.
Earlier development snapshots lacking limit/usage state are not migrated.

The live deadline includes store callbacks, but a persisted duration can only
account through the snapshot taken **before** its own commit. That commit and
any work after the last successful snapshot cannot be measured exactly after
a process dies. This is not a hard cross-process wall-clock/billing quota;
hosts needing one must maintain authoritative timing/reservations externally.

An interrupted checkpoint is never automatically replayed, even if a limit
caused the interruption. External leaf reconciliation accounts a verified
request/tool as one attempt. For a duration-limited execution, the host must
provide `elapsed:` for the interrupted attempt to `confirmCompletion`; silently
resetting lost execution time would bypass the limit. Measure/estimate it
conservatively only after stopping/fencing the old worker. In an unlimited run,
omitting it leaves unconfirmed elapsed time outside the reported duration.

`WorkflowExecutionUsage` reports attempts, **not tokens or money**. There is no
provider-independent token/cost quota, pricing catalog, automatic context
compaction, scheduler, persistent event store or resource sandbox here.
