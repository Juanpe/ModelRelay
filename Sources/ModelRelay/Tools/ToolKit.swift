import Foundation

/// A set of tools defined once and shared by many agent steps, such as all
/// the calls to one API. Agents name it by `id`. A kit with a `server` gets
/// its tools from that server (an MCP server) when a step runs.
public struct ToolKit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var tools: [AgentTool]
    public var server: ToolServer?

    public init(id: String, name: String, summary: String = "", tools: [AgentTool], server: ToolServer? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tools = tools
        self.server = server
    }
}
