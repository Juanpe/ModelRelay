# Retired compatibility experiment

The adapter/transcript bridge prototype has been retired. ModelRelay now
uses AnyLanguageModel 1.0.0 natively, without the FoundationModels round trip.
Its production HTTP-stub integration tests live in
`Tests/ModelRelayNetworkTests/NativeProviderTests.swift`.

Removing the SDK's SwiftScript dependency removes the SwiftSyntax conflict;
no patched AnyLanguageModel manifest or fork is required. Developer code is
supplied directly through `Step.custom` closures.

See [migration notes](../../Documentation/NativeRuntimeMigration.md).
The [alignment report](Alignment) is historical, not a current build recipe.
