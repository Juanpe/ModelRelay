# 🔒 Execution safety

[← README](../README.md) · [Context and policies](ContextAndPolicies.md) · [Recovery](Recovery.md)

Validate first, keep useful errors, observe progress and cap the work.
The same controls apply to direct and streaming executions.

[✅ Validation](#validation-before-execution) · [🩺 Errors](#structured-failures-and-retained-causes) · [📡 Events](#metadata-only-execution-events) · [⏱ Limits](#global-limits-and-usage)

<a name="validation-before-execution"></a>

## ✅ Catch invalid definitions early

`await executor.validate(workflow)` returns `[WorkflowValidationIssue]`
without loading models, fetching credentials or discovering MCP tools.
Execution validates automatically; calling it yourself is optional.

| Checked before work | Checked during execution |
| --- | --- |
| Schema, unique/unreserved names, references and explicit output | Dynamic response fields |
| Registered models/fallbacks and capabilities | Model readiness and credentials |
| Field, label and question schemas; local tool names | Remote tool schemas and returned values |

Every branch is checked, even if it will not run. A compatible fallback can
cover a primary's missing capability; an unknown model ID is a configuration error.

Invalid definitions throw `WorkflowValidationError` with aggregate `issues`.
Context/approval guards retain their dedicated `RelayError`/`RecoveryError` cases.
Missing dynamic fields fail before substitution or dispatch; use explicit
`Value.null` for null. Invalid output never silently selects another result.
Custom code is not inspected.

<a name="structured-failures-and-retained-causes"></a>

## 🩺 Keep the original cause

```swift
do {
    _ = try await executor.run(workflow, input: input)
} catch RelayError.operationFailed(let step, let failure) {
    print(step, failure.info.category, failure.info.message)
}
```

| API | Use it for |
| --- | --- |
| `failure.info` | Serializable category, message and `outcomeUncertain` |
| `failure.underlyingError` | Original in-memory error |
| `failure.rootCause` | Cause with native tool/executor wrappers unwrapped |
| `WorkflowFailureClassifiable` | Categories for your own integration errors |
| `HTTPResponseFailure.status` | Typed HTTP request status |

MCP and decision integrations classify their own errors. Public native
generation errors are classified too; upstream HTTP errors without a public
typed status remain `.unknown`, rather than guessing from message text.
Failure equality compares summaries, not raw error identity.

> ⚠️ Raw causes are not Codable and never enter events/checkpoints.
> They may contain server-echoed secrets. Inspect them deliberately; do not
> dump them into logs. Summaries and step records can still contain user data.

Configured request credentials, including URL/JSON-escaped forms, are
redacted from descriptions and summaries. Arbitrary provider output is not
automatically safe telemetry.

A dispatched write is uncertain on failure, including when an agent writes
successfully but fails to answer afterward. Custom bodies are conservatively
effectful. Cancellation, policy denials and exhausted limits do not trigger
fallback; a timeout or cancellation also does not prove a write never happened.

<a name="metadata-only-execution-events"></a>

## 📡 Stream progress

```swift
let execution = executor.execute(workflow, input: input)
defer { execution.cancel() }

for try await update in execution.updates {
    switch update {
    case .event(let event): print(event.kind.rawValue, event.step ?? "")
    case .step(let record): print("Finished", record.step)
    }
}

let report = try await execution.result
```

`WorkflowExecution` owns the running task, its `result` and cancellation.
`updates` is a native `AsyncThrowingStream<WorkflowExecutionUpdate, any Error>`,
not a custom sequence. Updates are `.event` metadata or `.step` records,
which can contain user input/output.
A failed step yields its record before iteration throws the original error;
`result` throws the same error, retaining its typed cause.

| Only need the result | Also need live updates |
| --- | --- |
| `run` | `execute` |
| `start` | `startExecution` |
| `resume` | `resumeExecution` |

Executions start immediately. Their updates have one consumer, not broadcast subscribers.
Awaiting `result` neither consumes updates nor executes work again.
Updates buffer without dropping; a slow consumer can grow the backlog in
memory. Use the direct API if you do not need progress.

| Events contain | Events do not contain |
| --- | --- |
| Execution/invocation IDs and sequence | Prompts or results |
| Declared step/model/tool names | Arguments or URLs |
| Failure category, checkpoint generation, limit | Raw errors or credentials |

Events cover execution, steps, models, tools, fallback, approval, successful
checkpoint saves and exhausted limits. Host-defined names can still be sensitive.

- Handle updates in your consuming task, including a UI-isolated task.
- Metadata sequence numbers are ordered within an invocation. Parallel step
  records arrive in completion order; the final report uses declaration order.
- `executionID` survives resume; `invocationID` changes and `sequence` restarts.
  Validation errors reach iteration and `result` before lifecycle events begin.
- Step records are enqueued before the post-step save; consumption may happen
  later. `checkpointSaved` is emitted only after successful store acknowledgement.

Keep the execution handle alive while consuming updates. Releasing it requests
cancellation, even if you retained a copy of `updates` or its iterator.
Use `defer { execution.cancel() }` so a `break` or an error in your loop body
stops retained work.

Cancellation while awaiting an update cancels execution through the native
stream's termination handler; iteration can end normally on cancellation.
Call `execution.cancel()` to stop explicitly, then await `result` to wait for
cooperative cleanup and observe success or failure.
Cancelling a task awaiting `result` cancels execution too. Finishing updates
does not discard the result.

> 📣 Events are not token streaming or a durable journal. A process can die
> after commit but before notification. If a save fails, reload the store:
> it may have committed without returning an acknowledgement.

<a name="global-limits-and-usage"></a>

## ⏱ Bound the work

```swift
let executor = WorkflowExecutor(limits: .init(
    maxDuration: .seconds(60),
    maxModelCalls: 8,
    maxToolCalls: 12,
    maxConcurrentSteps: 2
))
let report = try await executor.run(workflow, input: input)
print(report.usage.modelCalls, report.usage.toolCalls)
```

| Limit | Counts or bounds | Does not cover |
| --- | --- | --- |
| `maxModelCalls` | Native session/decision attempts, fallback and factory preparation | Hidden provider HTTP/continuation rounds |
| `maxToolCalls` | Admitted HTTP/MCP/direct-request attempts, including preparation or write-approval failures | Policy-denied calls, discovery, auth or listing |
| `maxConcurrentSteps` | Leaf bodies across nested parallel blocks; blocks hold no slot | Parallel tool calls inside one native agent response |
| `maxDuration` | Active invocation time, including preparation, requests, write approvals and store operations | Human review between invocations |

Defaults are unlimited. Counts/duration may be zero; concurrency must be
positive. Invalid values throw `RelayError.invalidLimits` before work.
Call-level limits only narrow the executor's ceiling.

Reservations are atomic across branches. Independent executions have
independent counters. Reaching a limit throws `RelayError.limitExceeded`,
never fallback. `WorkflowExecutionUsage` reports attempts, not tokens or money.

### ⏸ Budgets survive resume

Schema 2 checkpoints retain limits, confirmed counters and accumulated
active duration. Resume can only narrow them. Tightening limits while awaiting
approval saves a new generation, invalidating older decisions. Earlier
development checkpoint shapes are not migrated.

### ⚠️ A deadline is cooperative, not a billing meter

Providers, custom bodies and stores must honor cancellation; a blocking
closure cannot be forcibly stopped, and OS deadlines still apply.

The live deadline includes store callbacks. A stored duration only reaches
the snapshot taken **before its own commit**: that commit and unsaved work
cannot be timed exactly after process death. Keep authoritative timing and
reservations outside the SDK if you need a hard cross-process quota.

For interrupted leaf reconciliation, stop/fence the old worker first.
`confirmCompletion` counts a verified request/tool as one attempt and
requires `elapsed:` when duration-limited. Without a duration limit, omitting
it leaves unconfirmed time out of the report. Measure or conservatively
estimate it; never reset consumed time to bypass a limit.

Interrupted work is not automatically replayed, including limit failures.
See [recovery](Recovery.md) before deciding what may run again.
