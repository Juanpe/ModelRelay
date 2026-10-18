import Foundation

/// A tool an agent step may call: an HTTP request whose templates can read the
/// arguments the model chose as `{{args.NAME}}`, plus earlier results and
/// secrets like any request step.
public struct AgentTool: Codable, Sendable, Hashable {
    /// Small models can loop on tools; one agent step makes at most this many calls.
    public static let maxCallsPerStep = 6
    /// Tool output is trimmed to this many characters before the model reads it.
    static let maxOutputCharacters = 4000

    public var name: String
    public var description: String
    public var parameters: [Field]
    public var request: HTTPRequest

    public init(name: String, description: String, parameters: [Field] = [], request: HTTPRequest) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.request = request
    }
}
