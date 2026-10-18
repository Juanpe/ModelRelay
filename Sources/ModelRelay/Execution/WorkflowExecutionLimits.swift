import Foundation

/// Limits on executor-mediated work, not a sandbox for host code. Model calls
/// count session/decision attempts (including fallback), not provider-internal
/// HTTP continuation rounds. Tool calls include direct HTTP request steps.
public struct WorkflowExecutionLimits: Codable, Sendable, Hashable {
    public var maxDuration: Duration?
    public var maxModelCalls: Int?
    public var maxToolCalls: Int?
    /// Concurrent leaf steps; blocks do not hold slots, preventing nested deadlock.
    public var maxConcurrentSteps: Int?
    public init(
        maxDuration: Duration? = nil,
        maxModelCalls: Int? = nil,
        maxToolCalls: Int? = nil,
        maxConcurrentSteps: Int? = nil
    ) {
        self.maxDuration = maxDuration; self.maxModelCalls = maxModelCalls
        self.maxToolCalls = maxToolCalls; self.maxConcurrentSteps = maxConcurrentSteps
    }

    public static let unlimited = Self()

    func validate() throws {
        guard maxDuration.map({ $0 >= .zero }) ?? true,
              maxModelCalls.map({ $0 >= 0 }) ?? true, maxToolCalls.map({ $0 >= 0 }) ?? true,
              maxConcurrentSteps.map({ $0 > 0 }) ?? true
        else {
            throw RelayError.invalidLimits
        }
    }

    func narrowed(by other: Self) -> Self {
        func smaller<T: Comparable>(_ a: T?, _ b: T?) -> T? {
            switch (a, b) { case let (.some(a), .some(b)): min(a, b); default: a ?? b }
        }
        return Self(
            maxDuration: smaller(maxDuration, other.maxDuration),
            maxModelCalls: smaller(maxModelCalls, other.maxModelCalls),
            maxToolCalls: smaller(maxToolCalls, other.maxToolCalls),
            maxConcurrentSteps: smaller(maxConcurrentSteps, other.maxConcurrentSteps)
        )
    }
}

public enum WorkflowExecutionLimit: String, Codable, Sendable, Hashable {
    case duration, modelCalls, toolCalls
}
