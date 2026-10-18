import Foundation

/// Where a tool set's tools come from when a server (an MCP server) offers
/// them, rather than requests defined here.
public struct ToolServer: Codable, Sendable, Hashable {
    public var url: String
    /// Sent with every call. Values may use `{{secret.NAME}}`.
    public var headers: [HTTPRequest.Header]
    /// The person signs in to the server (OAuth); the app keeps the tokens.
    public var signsIn: Bool

    public init(url: String, headers: [HTTPRequest.Header] = [], signsIn: Bool = false) {
        self.url = url
        self.headers = headers
        self.signsIn = signsIn
    }
}

/// A tool a server offers, as it describes itself.
public struct ServerTool: Codable, Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String
    public var parameters: [Field]
    /// Parameters the tool can't do without.
    public var required: [String]
    /// Unless the server marks a tool read-only, it may change something,
    /// and needs the same permission as a write request.
    public var changesSomething: Bool

    public init(
        name: String,
        title: String? = nil,
        description: String,
        parameters: [Field] = [],
        required: [String] = [],
        changesSomething: Bool = true
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.parameters = parameters
        self.required = required
        self.changesSomething = changesSomething
    }
}

/// One open connection to a tool server.
public protocol ToolServerConnection: Sendable {
    func tools() async throws -> [ServerTool]
    func call(_ tool: String, arguments: [String: Value]) async throws -> Value
}

/// Opens connections to tool servers. ModelRelay has no network code of its
/// own: apps pass one (ModelRelayMCP connects to MCP servers).
public protocol ToolServerConnector: Sendable {
    func connect(to kit: ToolKit) async throws -> any ToolServerConnection
}
