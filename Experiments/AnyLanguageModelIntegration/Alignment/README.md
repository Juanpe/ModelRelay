# Historical SwiftSyntax alignment result

The October 15, 2026 experiment verified that AnyLanguageModel 1.0.0 could
compile with SwiftSyntax 603.0.2 after changing one manifest requirement:
95 core, 8 interpreter and 1 native macro/script smoke test passed together;
70 selected upstream macro/schema tests also passed. This was a dependency
compatibility check, not live-provider validation.

**Superseded:** ModelRelay no longer depends on SwiftScript or ShellKit.
It uses the unmodified AnyLanguageModel 1.0.0 release and its SwiftSyntax
602 requirement. The temporary alignment fixtures and runtime bridge have
been retired; they are not required to build the SDK.

See [native runtime migration](../../../Documentation/NativeRuntimeMigration.md).
