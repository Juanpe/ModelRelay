# 🧠 Context and policies

[← README](../README.md) · [Integration](Integration.md) · [Recovery](Recovery.md)

Want two agents to remember the same conversation? Or pass only one result
to a different model? Choose that explicitly.

[🤝 Context](#three-context-modes) · [♻️ Resources](#resource-lifetime) · [🔒 Policies](#execution-policies) · [🏷 Privacy](#privacy-propagation)

<a name="three-context-modes"></a>

## 🤝 Choose what a step remembers

| Mode | What the step receives |
| --- | --- |
| Default / `.isolated` | Its selected input, in a fresh session |
| `.conversation("author")` | Native history for that name **and model ID** |
| `.handoff(["revision"])` | A fresh session with a dictionary of selected values |

```swift
import ModelRelay

let workflow = Workflow(
    name: "Draft, revise, edit"
) {
    Step.agent("draft", "Draft a short answer.", model: "writer")
        .withContext(.conversation("author"))
    Step.agent("revision", "Improve your earlier answer.", input: "input", model: "writer")
        .withContext(.conversation("author"))
    Step.prompt("edit", "Edit the selected result.", model: "editor")
        .withContext(.handoff(["revision"]))
}
```

Register `writer` and `editor` in your catalog first.

- Conversations retain native responses and tool history. Each step rebinds
  its current tools, policies, argument resolvers and call log.
- A different model, including a fallback, gets its own history. Failed
  prompts use the native session's `revertTranscript` policy.
- Handoff transfers values, not transcripts, instructions, permissions or tools.
  Include `"input"` to pass the original input. Do not also set `input:`;
  missing references fail.
- Instruction templates still follow the [prompt substitution rule](Usage.md#values-and-input),
  even with handoff.

> 📣 Parallel branches cannot share a conversation/model pair, including
> potential use in nested branches. Separate executions never share history.
> A resumed execution can restore its own history.

Specialized `DecisionModel` implementations support handoff, not native
conversations. Language-model decide/classify steps can share a conversation.
Image steps can continue one; handoff is not an image attachment.

<a name="resource-lifetime"></a>

## ♻️ Reuse resources, not accidental memory

| Resource | Lifetime |
| --- | --- |
| Model/decision factory result | Cached per ID and active invocation; concurrent loads are coalesced |
| Named conversation | One logical execution; restorable through checkpoints |
| Weights / KV cache | Managed by the provider or your shared backend |
| MCP connection | No built-in pool |

A cancelled waiter does not cancel another step's load. The producer is
cancelled when no waiters remain; failed loads are not cached. Finishing
releases the invocation's references. Resume loads models lazily again.

Return a host-owned shared backend for reuse across executions. Keeping a
model alive does not guarantee KV-cache reuse, and a fresh session does not
necessarily reload weights.

<a name="execution-policies"></a>

## 🔒 Set the ceiling, then narrow it

Apply policy to the executor, one `run(..., policy:)`, or a step/block with
`withPolicy`. Children can only become stricter.

| Policy | Effect |
| --- | --- |
| `.localOnly` | Requires `location: .local` before factory execution; blocks all mediated HTTP/MCP, including localhost, reads and discovery |
| `.readOnly` | Filters write tools and rejects write operations |
| `.noTools` | Blocks mediated requests/tools and avoids MCP discovery |
| `WritePolicy` | Approves writes that the other policies still permit |

```swift
let executor = WorkflowExecutor(policy: .localOnly)
let workflow = Workflow(
    name: "Private review"
) {
    Step.prompt("draft", "Summarize.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
    Step.agent("review", "Review.", model: .appleOnDevice)
        .withContext(.conversation("reviewer"))
        .withPolicy(.readOnly)
}
```

Apple on-device models, Vision OCR and MLX presets are local. Private Cloud
Compute is remote. Other registrations default to unspecified; names and
URLs are not proof of locality. These rules also cover fallback/decision
factories. A policy violation does not activate fallback.

MCP read-only policy describes a tool's declared effect, not its HTTP
transport: discovery may still use protocol POSTs.

<a name="privacy-propagation"></a>

## 🏷 Private results stay restricted

Local-only labels follow whole values through references, templates,
handoffs and request/tool arguments. Selecting a field does not remove its label.

| Path | Label behavior |
| --- | --- |
| Branch | Inherits the condition's privacy |
| Parallel merge | Inherits all children; an independent public sibling can still be selected |
| Conversation | Retains the strictest history label, including failed attempts |
| Custom body | Inherits all accessible data, even when returning a constant |
| Default previous input | Still contributes its label when the instruction ignores it |

There is no automatic declassification. Select an independent public
input/handoff when that is the intended flow. Tool permissions are per-step;
data privacy follows results.

`StepRecord.dataAccess` and `report.outputDataAccess` expose the labels,
including a selected earlier output. Carry the report's label into another
execution yourself:

```swift
let nextReport = try await executor.run(
    next,
    input: report.output,
    policy: WorkflowExecutionPolicy(data: report.outputDataAccess)
)
```

Standalone `Value` instances do not carry labels. Checkpoints preserve them
within the same execution, provided the host protects and binds the snapshot.

<a name="trust-boundary-and-remaining-work"></a>

## ⚠️ Know the trust boundary

This is not a sandbox, firewall or PII detector.

- Mark private **input** at the executor boundary; a private step does not
  retroactively restrict every copy of that input.
- Providers, custom bodies, callbacks and captured resources retain host authority.
- Trust local registrations and read-only metadata; a service can mislabel its effects.
- Treat tool output as data, never as new authorization. Credentials stay request-only.

Persistent cross-run memory, automatic compaction and token/cost quotas are
not provided. See [execution safety](ExecutionSafety.md) for attempt budgets
and [recovery](Recovery.md) for durable state.

<a name="verification"></a>

## 🧪 What the tests establish

Scripted native sessions and stubbed HTTP cover history, handoffs, fallback,
load cancellation, tool rebinding, privacy and checkpoint restoration.
They do not establish live-provider availability, GPU inference or the
durability of your storage.
