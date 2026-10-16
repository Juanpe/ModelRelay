# ModelRelay

Open-source Swift SDK (MIT) for composing language-model workflows on
AnyLanguageModel. Client UI, accounts, storage and sign-in presentation
belong in the host, not this package.

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
7. Test behavior through `ScriptedModel`'s real native session path.
   Use `StubProtocol` for networking; no live server or key in default tests.
8. Credentials stay request-only, never in prompts, records or descriptions.
   Non-GET writes require an explicit `WritePolicy` and are never retried.

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
