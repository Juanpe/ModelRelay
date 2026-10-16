# Context, resources and execution policies

ModelRelay coordinates native AnyLanguageModel sessions. It does not add a
second inference runtime, translate transcripts or reconstruct agents from
model-generated code. All state described here lives inside one `run` call.

## Three context modes

Steps are isolated by default (`context == nil`, or `.isolated`). Reusing a
model, tool kit or instruction does not implicitly share a conversation.

```swift
let workflow = Workflow("Draft, revise, edit") {
    Step.agent("draft", "Draft a short answer.", model: "writer")
        .withContext(.conversation("author"))
    Step.agent("revision", "Improve your earlier answer.", input: "input", model: "writer")
        .withContext(.conversation("author"))
    Step.prompt("edit", "Edit the selected result.", model: "editor")
        .withContext(.handoff(["revision"]))
}
```

- `conversation(name)` reuses one actual native session for that name **and
  model ID**. Earlier prompts, responses and tool history remain native,
  including opaque provider state. Current tools, policies, argument
  resolvers and call logs are rebound with native dynamic instructions.
- `handoff(references)` starts a fresh session with a dictionary containing
  only the selected values as its input. No implicit previous value or
  original workflow input is added. Include `"input"` if it is needed.
  Explicit instruction templates still read their declared references as
  usual; the existing template rule can replace the ordinary input prompt.
  Handoff cannot also specify `input:`. Missing references throw.
- Handoff transfers values, not instructions, permissions, a transcript or
  tools. A new provider does not get another provider's signatures, hidden
  reasoning state or raw tool-call metadata.

The same conversation name with two model IDs means two separate sessions.
A fallback therefore has its own history, not an automatic copy of the
primary model's transcript. To transfer information across models, explicitly
select values or templates. Failed prompts roll back through the native
session's `revertTranscript` policy. There is still at most one fallback,
and no fallback after a tool attempt. No exactly-once recovery is claimed.

Specialized `DecisionModel` implementations have no native conversation:
use handoff for them. Language-model decide/classify steps can participate
in a native conversation. Image steps can continue a conversation, but
handoff is text/value input, not an image attachment.

Parallel branches may use different conversations. Sharing the same
name/model between branches is rejected before any work runs, including
possible use inside nested conditional branches. This conservative check
avoids scheduling-dependent history and concurrent mutation of a session.
Neither sequential nor overlapping runs on the same executor share history.

## Resource lifetime

Factories are coalesced and cached per model ID and run, separately for
language models and decision models. Sharing a backend does not opt into
conversation history. A cancelled or timed-out waiter leaves independently;
the shared producer is cancelled only when no waiting step needs it.
Failed loads are not cached. The run releases its own references at the end.

For resource reuse across runs, return a host-owned shared backend or use
the provider's cache. We do not promise that a fresh session reloads weights,
nor that retaining a model guarantees KV-cache reuse. Native resource
management remains the provider's responsibility. Cancellation and timeout
are cooperative, not a way to terminate arbitrary blocking Swift code.

## Execution policies

`WorkflowExecutor(policy:)` sets the ceiling. `run(..., policy:)` can narrow
one execution, and `step.withPolicy(...)` narrows a step or block. Combining
policies always picks the stricter restriction;
children cannot grant themselves permissions removed by their parent.

```swift
let executor = WorkflowExecutor(policy: .localOnly)
let workflow = Workflow("Private review") {
    Step.prompt("draft", "Summarize.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
    Step.agent("review", "Review.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
        .withPolicy(.readOnly)
}
```

- `data: .localOnly` permits only catalog entries explicitly declared
  `location: .local`. Remote and unspecified entries are rejected before
  factory execution, including a fallback and specialized decision models.
  It also blocks all executor-mediated HTTP and MCP operations, including reads,
  localhost endpoints and MCP discovery/sign-in connector callbacks.
- `tools: .readOnly` filters agent tools and rejects operations marked as
  writes, including direct HTTP request steps and direct named tool calls.
  MCP discovery may use protocol POSTs: read-only here describes the tool's
  declared effect, not its transport method.
- `tools: .denied` (`.noTools`) blocks mediated requests/tool calls and does
  not connect to MCP servers to populate an agent's tools.
- `WritePolicy` still authorizes permitted writes. Approval cannot override
  a read-only, no-tools or local-only restriction. Policy violations are
  configuration/control errors, not a reason to try another model.

On-device Apple models, Vision OCR and MLX presets are declared local.
Private Cloud Compute is off-device and declared remote. Other registrations
default to unspecified, rather than guessing trust from a name or URL.

## Privacy propagation

Local-only restrictions accompany results, not just the generating step:

- Explicit input references, handoff values, instruction templates and
  request/tool argument templates inherit their referenced values' labels.
- A branch inherits the privacy of its condition, not just its output text.
  A parallel merge inherits all its children; an explicitly selected public
  sibling can still be used independently.
- A native conversation retains its most restrictive data label, including
  failed attempts. A later step cannot forget the privacy of earlier history.
- A custom body can read the original input and every result, so its output
  conservatively inherits all those restrictions, even if it returns a
  constant or uses an explicit public input. There is no automatic declassification.

Labels attach to whole step values. Selecting a field from a restricted
dictionary does not automatically declassify that field.

The default previous-value flow is conservative: even an instruction or
template that happens not to use its incoming value inherits its label.
Select an independent public input/handoff when that is the intended flow.
Per-step tool permissions do not taint unrelated later steps; data privacy does.

Step records expose `dataAccess` and the selected conversation name; reports
expose `outputDataAccess`, including when `Workflow.output` selects an
earlier result. Values themselves are unchanged. When passing a report's
output to another run, the host must carry that label into its new executor
policy (for example `executor.run(next, input: report.output,
policy: WorkflowExecutionPolicy(data: report.outputDataAccess))`). This is not a
general cross-process information-flow system: standalone `Value`s do not
carry labels. Recoverable execution checkpoints preserve them within the
same logical run; the host must protect and correctly bind those snapshots.

## Trust boundary and remaining work

This is **not a sandbox, network firewall or automatic PII detector**.
Providers declared local must actually be local. Host code, custom bodies,
credential providers, observers and captured resources retain their authority.
Mark private input with the executor's policy; a private step does not
retroactively classify other copies of the original input.

Read-only HTTP methods and MCP tool metadata must be trustworthy. A remote
service can mislabel its effects; ModelRelay cannot prove that a GET or
read-only-annotated tool does not write. Tool output is untrusted data,
never an authorization change. Credentials remain request-only.

The separate [recovery API](Recovery.md) supports checkpoint/approval/resume
with a host-owned atomic durable store. There is no built-in persistence
implementation, automatic context compaction, token/cost budget or MCP
connection pool. These are not hidden promises of session reuse.

## Verification

The macOS 27 / Swift 6.4 suite passes with Swift warnings-as-errors:
198 core and 34 HTTP/provider/MCP test definitions (232 total). Tests use
scripted native sessions and local HTTP/SSE fixtures, not live model calls.
Coverage includes native session reuse, handoff isolation, model-specific
fallback history, concurrent load cancellation, old tool revocation,
policy inheritance, privacy propagation, blocked transports/factories and
checkpoint restoration/failure safety. Recovery tests also verify retained
Anthropic reasoning/tool history through actual providers with stubbed HTTP.
The [execution safety layer](ExecutionSafety.md) adds strict preflight,
retained typed failures, metadata-only events and resumable global limits.
The standalone consumer exercises Codable context metadata and privacy
labels without inference. MLX compilation is checked separately; GPU inference
and real-provider behavior are not established by these offline tests.
