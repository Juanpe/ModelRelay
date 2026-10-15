# Standalone ModelRelay client

A consumer package that links only `ModelRelay` from the local checkout.
No application project, UI, credentials or optional model integration is
needed. Requires Xcode 27 / Swift 6.4 and macOS 27.

From the repository root:

```sh
swift run --package-path Examples/StandaloneClient StandaloneClient
```

The default workflow is deterministic and makes no model or network calls.
It demonstrates construction-time conditions, parallel steps, explicit
result references, progress callbacks and a Codable round-trip.

To opt into a real on-device model call:

```sh
swift run --package-path Examples/StandaloneClient StandaloneClient --apple
```

That path requires Apple's model to be available and ready on the device.

The manifest uses `.package(path: "../..", traits: [])` to test the current
SDK checkout. For a remote dependency, replace it with the URL and a version
or revision appropriate to your client. SwiftPM may resolve optional
dependencies, but this target compiles and links only the core product.
