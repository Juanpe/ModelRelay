# 📝 Changelog

[Version policy](Documentation/Releasing.md) · [README](README.md)

## [Unreleased]

First release target: **0.1.0**. No release tag has been published yet.

### Added

- Swift workflow builders with typed values, branching, parallel steps and custom async bodies.
- Per-step models, named conversations and explicit handoffs through AnyLanguageModel.
- HTTP tools, MCP/OAuth helpers, Jev decisions and opt-in MLX presets.
- Execution updates, reports, budgets, privacy/write policies and recoverable checkpoints.
- Support for iOS 18, macOS 15 and visionOS 2, with newer Apple features availability-gated.

### Improved

- Shared HTTP response handling with protocol-specific OAuth and MCP errors.
- Instance-owned cloud HTTP clients with injectable sessions, without mutable global transport state.

### Changed

- `DecisionsAPIModel` equality and hashing now include its HTTP session identity.
  Reuse the same session when models should compare equal; existing initializer calls remain valid.
