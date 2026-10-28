# 📝 Changelog

[Version policy](Documentation/Releasing.md) · [README](README.md)

## [Unreleased]

## [0.2.0] - 2026-10-28

### Added

- A `modelrelay` agent skill and Claude Code plugin marketplace, so coding agents in host apps
  add the package, use the docs of their resolved version and follow the SDK's safety contracts.
  `make check-skill` keeps its guide links and API names in sync with the package.
- `Field.Kind.object` groups fields, so `extract` steps and tool parameters can ask for
  lists of records such as `.list(.object([...]))`. Each object reads as a dictionary.
  Exhaustive `switch`es over `Field.Kind` need a case for it.
- Host tools: `HostTool`s in a `HostToolKit`, passed as `WorkflowExecutor(hostToolKits:)`, are
  tools the app writes in Swift, such as one that edits the app's own state. Agent and Use a Tool
  steps select them by kit id, so workflows stay Codable. Calls that change something follow the
  write policy; local-only executions may call them.

### Fixed

- Named schema nodes no longer share a definition when their names repeat (a tool and one of its
  choice parameters, or fields in different objects), which let one replace the other's shape.

## [0.1.0] - 2026-10-18

First public release.

### Added

- Swift workflow builders with typed values, branching, parallel steps and custom async bodies.
- Per-step models, named conversations and explicit handoffs through AnyLanguageModel.
- HTTP tools, MCP/OAuth helpers, Jev decisions and opt-in MLX presets.
- Execution updates, reports, budgets, privacy/write policies and recoverable checkpoints.
- Shared HTTP response handling with protocol-specific OAuth and MCP errors.
- Cloud models own their HTTP session: pass `session:` to `DecisionsAPIModel` to share one or
  inject a test transport. Equality and hashing include that session's identity.
- Support for iOS 18, macOS 15 and visionOS 2, with newer Apple features availability-gated.

[Unreleased]: https://github.com/Juanpe/ModelRelay/compare/0.2.0...HEAD
[0.2.0]: https://github.com/Juanpe/ModelRelay/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Juanpe/ModelRelay/releases/tag/0.1.0
