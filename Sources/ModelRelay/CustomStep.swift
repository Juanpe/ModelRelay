import Foundation

/// An immutable snapshot of the values available to a developer-defined step.
/// Parallel children receive independent snapshots, just like model steps.
public struct CustomStepContext: Sendable {
    public let input: Value
    public let workflowInput: Value
    public let results: [String: Value]

    /// Reads a completed step's value. No hidden conversation or secrets.
    public subscript(_ step: String) -> Value? { results[step] }
}

/// A compiled closure, identified by identity rather than executable contents.
/// Copies preserve identity; separately created closures are distinct.
///
/// Bodies have the host application's authority, including anything captured
/// by the closure. ModelRelay's WritePolicy does not sandbox developer code.
/// Cancellation/timeouts are cooperative: bodies must not block or ignore
/// cancellation. They run once, with no model fallback or automatic replay.
public struct CustomStepBody: Sendable, Hashable, Codable {
    private let id = UUID()
    private let body: @Sendable (CustomStepContext) async throws -> Value

    public init(_ body: @escaping @Sendable (CustomStepContext) async throws -> Value) {
        self.body = body
    }

    func call(_ context: CustomStepContext) async throws -> Value { try await body(context) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Executable bodies must never be reconstructed from untrusted data.
    public init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Custom step bodies cannot be decoded. Define the body in Swift code."
        ))
    }

    /// Fails rather than silently dropping code from a saved workflow.
    public func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(self, .init(
            codingPath: encoder.codingPath,
            debugDescription: "Custom step bodies cannot be encoded. This workflow is in-memory only."
        ))
    }
}
