# 🚚 Migrating to the native runtime

[← README](../README.md) · [Usage](Usage.md) · [Integration](Integration.md)

Moving from the earlier SDK? ModelRelay now uses the unmodified
AnyLanguageModel **1.0.0** release. No patched fork or transcript bridge is needed.

<a name="ownership"></a>

## 🧩 Who owns what?

| Layer | Responsibility |
| --- | --- |
| AnyLanguageModel | Inference, sessions, provider transcripts, structured generation and backend resources |
| ModelRelay | Workflow order, values, branches, fallback, permissions, records and recovery contracts |
| Your host | Credentials, UI, persistence and trusted custom code |

Apple models use the upstream integrations. Vision OCR implements the native
AnyLanguageModel protocol.
The core now targets iOS 18, macOS 15 and visionOS 2; newer Apple capabilities
are availability-gated. [Platform requirements →](../README.md#installation)

<a name="api-changes"></a>

## 🔄 Update these entry points

| Earlier API | Use now |
| --- | --- |
| Factories returning Apple's model protocol | `any AnyLanguageModel.LanguageModel` |
| `OpenAICompatibleModel` | `OpenAILanguageModel` from AnyLanguageModel |
| `ClaudeModel` | `AnthropicLanguageModel` from AnyLanguageModel |
| `WorkflowRunner` | `WorkflowExecutor` |
| `RunCheckpoint` / `RunCheckpointStore` | `WorkflowExecutionCheckpoint` / `WorkflowExecutionCheckpointStore` |
| `RunReport` / `RunOutcome` | `WorkflowExecutionReport` / `WorkflowExecutionOutcome` |
| `ExecutionPolicy` / `runID` | `WorkflowExecutionPolicy` / `executionID` |
| `onEvent:` / `onStep:` callbacks | `stream` / `startStream` / `resumeStream`, then `for try await` and `result` |
| Source-string script steps | Compiled `Step.custom` bodies |

Streaming is [single-consumer and cancellation-aware](ExecutionSafety.md#metadata-only-execution-events).
Direct `run` / `start` / `resume` still return their result without progress callbacks.

Import and declare AnyLanguageModel in clients that construct providers.
`ModelRelayCloud` now supplies specialized decisions such as Jev, not general
chat wrappers. Register custom vision entries with `supportsImages: true`;
the flag does not make a text-only model support images.

SwiftScript, ShellKit, `ModelRelayScript`, `ScriptLanguage` and `ScriptRunner`
are removed. SwiftSyntax remains an upstream macro dependency; no interpreter
forces a competing major version. MLX is now opt-in: select its product and
enable `traits: ["MLX"]`.

### 👨‍💻 Replace scripts with Swift

```swift
import Foundation
import ModelRelay

let workflow = Workflow(
    name: "Normalize"
) {
    Step.custom("clean") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    Step.template("message", "Cleaned: {{clean}}")
}
let report = try await WorkflowExecutor().run(workflow, input: .text("  Hello  "))
```

> ⚠️ Bodies are trusted Sendable async code, not sandboxed source. They can
> capture host resources and cannot be serialized. Rebuild the definition
> for recovery; keep execution checkpoints separately.
> [Custom-step contract →](Usage.md#custom-swift)

<a name="native-agent-execution"></a>

## 🤝 Check agent behavior

Tool-enabled steps consume the provider's native streaming tool loop internally.
Callers still get a final `Value` and normal records, not token streaming.

This handles the full Anthropic continuation in AnyLanguageModel 1.0.0;
its non-streaming path performs one tool round without requesting a final answer.
There is no second runtime replaying tools.

Host wrappers enforce permissions, secret isolation, output truncation and a
six-call step budget. Providers may be stricter. A host tool attempt prevents
fallback afterward.

Reusing a model does not share history automatically. Opt into
[conversations/handoff](ContextAndPolicies.md), or use
[checkpoints](Recovery.md) to restore the same logical execution. Renaming
steps cannot rewrite references hardcoded inside custom closures.

<a name="verification-at-the-runtime-migration-checkpoint"></a>

## 🧪 Verify your integration

```sh
env -u RELAY_LIVE swift test -Xswiftc -warnings-as-errors
env -u RELAY_LIVE swift run --package-path Examples/StandaloneClient StandaloneClient
swift build --traits MLX --target ModelRelayMLX -Xswiftc -warnings-as-errors
```

Tests use scripted native sessions and actual providers with stubbed HTTP/SSE.
The standalone client exercises Codable, custom bodies and recovery without
inference. MLX compilation is separate from Metal/GPU inference; upstream
C++ warnings may still occur.

These checks do not verify live services, weight downloads or every deployment
platform. The old adapter and SwiftSyntax 603 alignment experiments are retired.
