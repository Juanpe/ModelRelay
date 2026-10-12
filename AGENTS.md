# ModelRelay

Open-source Swift package (Apache 2.0) that runs chains of small
language-model steps on top of FoundationModels. The Switchboard app (private,
sibling repo) is its first client; nothing app-specific belongs here.

## Rules

1. Public API is small and documented. No SwiftUI, App Intents or persistence:
   if it needs a UI or knows about a user, it belongs in the app.
2. Models are FoundationModels `LanguageModel`s. Don't add a parallel provider
   abstraction; add executors or catalog entries instead.
3. Never execute model output or workflow content. Templates substitute only.
4. Never retry in a loop: at most one fallback model per step.
5. No secrets, downloads or network code in the core target; cloud and MLX
   integrations are separate products.
6. Swift 6.4, strict concurrency, no warnings, `ExistentialAny`.
7. Every behaviour has a test against `ScriptedModel` (the real session path).

## Commands

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer swift run relay-bench apple.on-device
```
