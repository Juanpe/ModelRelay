# Native AnyLanguageModel runtime

This is an intentional breaking migration of the standalone SDK. It does
not change any client application. ModelRelay now depends on the unmodified
AnyLanguageModel **1.0.0** release, not a local checkout or patched fork.

## Ownership

- AnyLanguageModel owns inference, native sessions, provider transcripts,
  structured generation, reasoning replay and backend resource lifecycle.
- ModelRelay owns workflow execution, values, branching/parallel snapshots,
  one fallback per model step, permissions and step records.
- The host owns credentials, persistence, user interaction and trusted
  custom code. MCP OAuth helpers still do not own sign-in UI or token storage.

There is no ModelRelay provider-to-FoundationModels adapter, transcript
converter or second conversation runtime. Apple models use the upstream
native integrations; Vision OCR is a native AnyLanguageModel implementation.

## API changes

1. Catalog factories return `any AnyLanguageModel.LanguageModel`, rather
   than Apple's protocol. Custom model implementations must adopt that
   protocol; models are not silently wrapped in a compatibility bridge.
2. Replace `OpenAICompatibleModel` with `OpenAILanguageModel`, and
   `ClaudeModel` with `AnthropicLanguageModel`. Import AnyLanguageModel and
   declare its product/dependency in clients that construct providers.
   Register a shared backend value when resource reuse is appropriate.
3. `ModelRelayCloud` now contains the specialized decisions API (such as
   Jev), not duplicated general-purpose chat providers.
4. Register vision-capable custom entries with `supportsImages: true`.
   There is no universal capability property in AnyLanguageModel 1.0.0.
   Built-in Apple entries consult their native image support.
5. SwiftScript, ShellKit, `ModelRelayScript`, `ScriptLanguage`, `ScriptRunner`
   and source-string script steps are removed from the SDK. Use a compiled
   custom body instead. A client may call its own interpreter inside that
   body if it explicitly wants a code editor/runtime.

```swift
import Foundation
import ModelRelay

let workflow = Workflow("Normalize") {
    Step.custom("clean") { context in
        .text(context.input.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    Step.template("message", "Cleaned: {{clean}}")
}
let report = try await WorkflowRunner().run(workflow, input: .text("  Hello  "))
```

Custom bodies are Sendable async throwing closures. They receive an immutable
value snapshot (`input`, `workflowInput`, `results`, or `context["step"]`).
They execute once without fallback; cancellation and timeout are cooperative.
They have the developer's ambient authority, including captured resources:
WritePolicy does not sandbox arbitrary Swift code. The context itself does
not expose runner secrets or transports.

Custom closures cannot be encoded or decoded. Saving a containing workflow,
including a nested custom body, throws explicitly. Declarative-only
workflows still round-trip. Renaming a step updates a custom step's explicit
input reference but cannot rewrite hardcoded references inside compiled code.

## Native agent execution

Steps with tools consume the native session's streaming response internally;
callers still receive the final Value and normal step records. This uses the
provider's complete tool loop. In AnyLanguageModel 1.0.0, Anthropic's
non-streaming response executes one tool round without requesting the final
answer; its streaming implementation handles the full continuation.

No tools are re-executed by a second runtime. ModelRelay's host tool wrappers
still enforce permissions, secret isolation, output truncation and the
six-call step budget. Providers may impose stricter limits, such as rejecting
an identical repeated tool round. After any host tool attempt, failure never
switches models or replays the write.

Reusing a model still does **not** implicitly share conversation history.
Each model step creates a fresh native session. Pass selected earlier results
through values/templates for explicit context handoff. Persistent agent
memory and context budgeting are not implemented by this migration.

## Verification

With Swift 6.4 / Xcode 27 on macOS 27, the default suite passes with
warnings-as-errors: **103 core + 30 network/provider/MCP test definitions**,
including 12 custom-body tests and parameterized cancellation coverage.
Three live Apple-model tests remain disabled. Provider tests use URLProtocol
HTTP/SSE fixtures with the actual OpenAI and Anthropic providers, not keys,
live services or inference. They verify tools once, permissions/secrets,
no replay after writes, fallback, dynamic types, images and reasoning-signature
replay within an Anthropic tool loop.

The standalone client also exercises declarative Codable round trips and a
custom-body workflow and compiles with Swift warnings-as-errors. The optional
`MLX` trait and `ModelRelayMLX` target also compile with Swift warnings-as-errors;
the upstream MLX Metal/C++ sources emit C++17-extension warnings. This is a
build check, not GPU inference. Real-provider behavior, weight downloads and
cross-platform deployment are not established by these offline tests.

```sh
env -u RELAY_LIVE swift test -Xswiftc -warnings-as-errors
env -u RELAY_LIVE swift run --package-path Examples/StandaloneClient StandaloneClient
swift build --traits MLX --target ModelRelayMLX -Xswiftc -warnings-as-errors
```

The older adapter experiment and 603 alignment fixtures are retired.
SwiftSyntax is still a transitive macro dependency of AnyLanguageModel, but
there is no longer an interpreter forcing a conflicting major version.
