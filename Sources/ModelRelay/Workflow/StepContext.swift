import Foundation

/// Native conversation history is opt-in, run-scoped and model-specific.
/// Different models never implicitly exchange provider transcripts.
public enum StepContext: Codable, Sendable, Hashable {
    case isolated
    /// Reuses one native session for this name AND model ID within one run.
    case conversation(String)
    /// Starts fresh with only these value references as its input dictionary.
    /// No previous input, tool history or provider metadata is copied.
    case handoff([String])
}
