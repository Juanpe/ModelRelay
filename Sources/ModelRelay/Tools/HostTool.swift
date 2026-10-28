import Foundation

/// A tool the app implements in Swift, such as one that edits the app's own
/// state. Agents and Use a Tool steps select it through a `HostToolKit` by id,
/// so the workflow stays Codable while the body stays in memory.
///
/// Bodies have the host application's authority, like custom steps. A call
/// that changes something asks the executor's `writePolicy` first (it sees a
/// POST to `host:<kit id>` whose body names the tool and its arguments), runs
/// once and is never retried. Host tools reach no network themselves, so
/// local-only executions may call them.
public struct HostTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: [Field]
    /// Unless the tool is marked read-only, it may change something and needs
    /// the same permission as a write request.
    public let changesSomething: Bool
    private let body: @Sendable ([String: Value]) async throws -> Value

    public init(
        name: String,
        description: String,
        parameters: [Field] = [],
        changesSomething: Bool = true,
        body: @escaping @Sendable (_ arguments: [String: Value]) async throws -> Value
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.changesSomething = changesSomething
        self.body = body
    }

    /// How the tool describes itself to models and policies.
    var serverTool: ServerTool {
        ServerTool(
            name: name,
            description: description,
            parameters: parameters,
            required: parameters.map(\.name),
            changesSomething: changesSomething
        )
    }

    func call(_ arguments: [String: Value]) async throws -> Value {
        try await body(arguments)
    }
}

/// Host tools shared by many steps. Steps name it by `id`, like a `ToolKit`;
/// the two share one set of ids.
public struct HostToolKit: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let tools: [HostTool]

    public init(id: String, name: String, tools: [HostTool]) {
        self.id = id
        self.name = name
        self.tools = tools
    }

    /// The kit as tool runtimes read it: no request tools and no server.
    var toolKit: ToolKit {
        ToolKit(id: id, name: name, tools: [])
    }

    var connection: HostToolConnection {
        HostToolConnection(kit: self)
    }
}

/// A host tool kit as an in-process tool server: no connector, no network.
struct HostToolConnection: ToolServerConnection {
    let kit: HostToolKit

    func tools() async throws -> [ServerTool] {
        kit.tools.map(\.serverTool)
    }

    func call(_ tool: String, arguments: [String: Value]) async throws -> Value {
        guard let host = kit.tools.first(where: { $0.name == tool }) else {
            throw InvalidOutput(reason: "\(kit.name) has no tool “\(tool)”")
        }
        try Task.checkCancellation()

        return try await host.call(arguments)
    }
}
