# ModelRelay

Open-source Swift SDK (MIT) for composing language-model workflows on
AnyLanguageModel. Client UI, accounts, storage and sign-in presentation
belong in the host, not this package.

## 🗂 Layout

- `Sources/ModelRelay/`: `Workflow` definitions/DSL, `Execution` orchestration,
  `Models` providers/schemas, `Tools`, `Requests`, `Values` and `Errors`.
- Execution's `Steps`, `Runtime` and `Recovery` group its implementations.
  MCP separates protocol parsing from authentication.
- Tests mirror features; shared test doubles live in `Support`. Keep related
  test facets in named extensions without changing suite isolation.
- Keep folders shallow and feature-owned. No catch-all `Common` or `Utils`
  folders, parallel public/internal trees, or extra targets just for organization.

## 🧭 Rules

1. Keep public API small and documented. No SwiftUI, App Intents or
   persistence implementation in the core.
2. Use native AnyLanguageModel `LanguageModel`s. Do not add another provider
   abstraction or transcript bridge.
3. Never execute model output. Templates only substitute values. Custom steps
   run trusted, compiled Swift closures with values, not executor secrets.
   Their bodies are in-memory and non-serializable.
4. At most one fallback model per step; no retry loops.
5. Keep secrets, downloads and network implementations out of the core.
   Providers come from AnyLanguageModel; optional network products stay separate.
6. Swift 6.4, strict concurrency, no warnings, `ExistentialAny`.
   Support iOS 18, macOS 15 and visionOS 2; availability-gate newer Apple APIs.
7. Test behavior through `ScriptedModel`'s real native session path.
   Use `StubProtocol` for networking; no live server or key in default tests.
8. Credentials stay request-only, never in prompts, records or descriptions.
   Non-GET writes require an explicit `WritePolicy` and are never retried.
9. Expose progress through async sequences, not notification callbacks.
   Keep cancellation, final results and metadata-only events explicit.

## 🧱 Responsibilities and file size

- Aim for production files around 300 lines; review and split responsibilities
  before exceeding 400. Keep logical spacing and useful comments, not fewer lines.
- Use feature-named extensions for cohesive facets of the same type. Extract
  a helper type when it owns a separate responsibility or state; do not create
  numbered parts or a catch-all utilities file just to satisfy the line limit.
- Keep `WorkflowExecutor` an actor coordinator. Model requests, execution state
  and recovery mechanics have focused internal implementations; resources and
  conversations remain execution-local.
- `ExecutionArchitectureTests` recursively caps production/test files at 400
  lines and the executor facade at 200; core files belong in feature folders.
  A failing guard requires a design review, not a higher limit.
- Keep helpers private where possible and internal when shared across files.
  Do not widen public API or introduce global mutable state to make a split work.
- Split long functions by meaningful operations. Do not increase lint limits
  or grow the baseline to bypass a required responsibility review.

## 🎨 Swift style

- Keep `.swiftformat`, `.swiftlint.yml`, `.editorconfig` and the tool versions
  aligned with Runline. Use `make format`, not Xcode's separate `swift-format`.
- SwiftFormat 0.55.5 owns layout: four spaces, sorted imports (`@testable`
  last), outdented `#if` and multiline arguments/parameters before the first item.
  Put access modifiers on declarations, not extensions. Preserve explicit
  `self`, useful type annotations and enum raw values.
- Separate logical phases inside function bodies with one blank line:
  preparation, execution, validation/error handling and the final result.
  Keep related assignments and checks together; do not space every statement
  or pad the start/end of a body. Preserve these groups when formatting.
- Prefer `async/await` and async sequences. Cancel stored tasks explicitly;
  in long-lived weak-self loops, unwrap inside the loop, not before it.
- Reuse URL sessions; explicitly invalidate owned delegate sessions.
- New service protocols use `Protocol`; ViewModel protocols use `Modeling`.
  Do not rename existing public API just to satisfy a style rule.
- `make check-style` checks formatting and SwiftLint 0.65.1 with the checked-in
  baseline. `make lint-all` exposes existing debt. Do not grow the baseline
  to hide new violations; remove entries as debt is fixed. Analyzer rules
  require a compiler log and are separate from these lint checks.
- Dependencies, generated files and recovered source copies are excluded.
  The tool bootstrap downloads checksum-verified binaries into ignored `.tools/`.

## ✍️ Documentation style

- Follow the root README's English, friendly, example-first voice.
  Use short sections, helpful emoji headings, mapping tables and brief callouts.
- Keep one home for each contract; link to it instead of repeating paragraphs.
  Explain required safety/recovery details without hiding them behind vague claims.
- Prefer multiline `Workflow(name: …, output: …)` examples. No em dashes.
  Keep working links/anchors when renaming headings.
- Comments explain non-obvious intent or constraints, not what names already say.
  Prefer one-line type summaries when useful; expand only when needed.

## 🧪 Checks

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer env -u RELAY_LIVE swift test -Xswiftc -warnings-as-errors
```

`RELAY_LIVE=1` opts into real Apple-model tests. For a manual benchmark:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer swift run relay-bench apple.on-device
```
