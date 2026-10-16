# 🧪 Try ModelRelay without a model

[← README](../../README.md) · [Usage recipes](../../Documentation/Usage.md)

A small consumer package for the local SDK checkout. No API key, model
download or UI needed. Requires Xcode 27 / Swift 6.4 and macOS 15+.

## ▶️ Run it

From the repository root:

```sh
swift run --package-path Examples/StandaloneClient StandaloneClient
```

| The example checks | Without… |
| --- | --- |
| Builders, parallel steps, result references and Codable | Inference or network calls |
| Validation, async progress, final reports, limits and typed failures | Real credentials |
| Custom bodies and privacy labels | An interpreter |
| Approval/checkpoint restore with a new executor | Serializing executable bodies |

> 📣 The demo checkpoint store is in-memory. Its JSON round-trip and
> compare-and-swap checks are not durable production storage.

## 🍎 Try the on-device model

```sh
swift run --package-path Examples/StandaloneClient StandaloneClient --apple
```

The `--apple` path needs macOS 26+ with Apple's model available and ready.

## 📦 Use it in your project

The manifest links only `ModelRelay` through
`.package(path: "../..", traits: [])`. For a remote dependency, follow the
[installation example](../../README.md#installation) and choose an appropriate
version/revision. SwiftPM may resolve optional dependencies without building them.
