# ModelRelay

Open-source Swift package (MIT) for composing language-model workflows on
AnyLanguageModel. This is an independent SDK: no client application's UI,
storage, identity or authentication presentation belongs here.

## Rules

1. Public API is small and documented. No SwiftUI, App Intents or persistence:
   if it needs a UI or knows about a user, it belongs in the app.
2. Models are AnyLanguageModel `LanguageModel`s. Don't add a parallel provider
   abstraction; add executors or catalog entries instead.
3. Never execute model output. Templates substitute only. Custom steps run
   trusted developer-supplied Swift closures, never source strings or model
   output. Bodies are in-memory only and receive values, not runner secrets.
4. Never retry in a loop: at most one fallback model per step.
5. No secrets, downloads or network code in the core target; provider implementations belong to AnyLanguageModel; optional network
   integrations are separate products.
6. Swift 6.4, strict concurrency, no warnings, `ExistentialAny`.
7. Every behaviour has a test against `ScriptedModel` (the real session path).
   Network code is tested against `StubProtocol`; tests never reach a real
   server or use a real key.
8. Secrets only reach request steps, never prompts, records or descriptions.
   Writes (non-GET requests) need an explicit `WritePolicy` and are never retried.

## Commands

`LiveAppleTests` run Apple's on-device model for real (APIs stay fake); they
only run with `RELAY_LIVE=1`.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer swift run relay-bench apple.on-device
```
