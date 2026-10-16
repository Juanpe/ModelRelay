import Foundation

/// Trust metadata supplied by the host, not inferred from a model's name or URL.
/// A local declaration is an assertion about the entire provider implementation.
public enum ModelLocation: String, Codable, Sendable, Hashable {
    case local, remote, unspecified
}

/// Restrictions on executor-mediated execution. A child/step can narrow but never
/// relax its parent's policy. Trusted providers/custom bodies are not sandboxed.
public struct WorkflowExecutionPolicy: Codable, Sendable, Hashable {
    public enum DataAccess: String, Codable, Sendable, Hashable {
        case unrestricted, localOnly
        func combined(with other: Self) -> Self { self == .localOnly || other == .localOnly ? .localOnly : .unrestricted }
    }
    public enum ToolAccess: String, Codable, Sendable, Hashable {
        case allowed, readOnly, denied
    }

    public var data: DataAccess
    public var tools: ToolAccess

    public init(data: DataAccess = .unrestricted, tools: ToolAccess = .allowed) {
        self.data = data
        self.tools = tools
    }

    public static let unrestricted = Self()
    /// Local inference only; HTTP and MCP operations are blocked, even reads.
    public static let localOnly = Self(data: .localOnly)
    public static let readOnly = Self(tools: .readOnly)
    public static let noTools = Self(tools: .denied)

    func combined(with other: Self) -> Self {
        let access: ToolAccess
        if tools == .denied || other.tools == .denied { access = .denied }
        else if tools == .readOnly || other.tools == .readOnly { access = .readOnly }
        else { access = .allowed }
        return Self(data: data.combined(with: other.data), tools: access)
    }

    func allowsTool(changesSomething: Bool) -> Bool {
        tools != .denied && !(tools == .readOnly && changesSomething)
    }

    func checkNetwork(step: String) throws {
        guard data != .localOnly else { throw RelayError.policyViolation(step: step, reason: "local-only data cannot reach HTTP or MCP") }
    }

    func checkTool(changesSomething: Bool, step: String) throws {
        guard allowsTool(changesSomething: changesSomething) else {
            throw RelayError.policyViolation(step: step, reason: "the execution policy does not allow this operation")
        }
    }
}

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
