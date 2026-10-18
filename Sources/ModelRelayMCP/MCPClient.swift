import Foundation
import ModelRelay

/// One session with an MCP server: `initialize`, then `tools/list` and
/// `tools/call` as JSON-RPC over HTTP POST. Replies may be JSON or a stream
/// of server-sent events.
public actor MCPClient: ToolServerConnection {
    static let protocolVersion = "2025-06-18"

    let url: URL
    let headers: [String: String]
    let clientName: String
    let session: URLSession
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1
    private var listed: [ServerTool]?

    init(url: URL, headers: [String: String], clientName: String, session: URLSession) {
        self.url = url
        self.headers = headers
        self.clientName = clientName
        self.session = session
    }

    func start() async throws {
        let result = try await send("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": clientName, "version": "1.0"],
        ])
        negotiatedVersion = result["protocolVersion"] as? String ?? Self.protocolVersion
        try await notify("notifications/initialized")
    }

    public func tools() async throws -> [ServerTool] {
        if let listed { return listed }

        var all: [ServerTool] = []
        var cursor: String?

        // A few pages at most; agents can't use hundreds of tools anyway.
        for _ in 0 ..< 10 {
            let result = try await send("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            for item in result["tools"] as? [[String: Any]] ?? [] {
                if let tool = MCPSchema.tool(from: item) { all.append(tool) }
            }

            guard let next = result["nextCursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }

        listed = all
        return all
    }

    public func call(_ tool: String, arguments: [String: Value]) async throws -> Value {
        let result = try await send("tools/call", params: [
            "name": tool,
            "arguments": arguments.mapValues(\.jsonObject),
        ])

        let value = MCPSchema.value(fromCallResult: result)
        if result["isError"] as? Bool == true { throw MCPError.toolFailed(value.textValue) }

        return value
    }

    // MARK: - JSON-RPC

    private func send(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (data, response) = try await post(message)

        if method == "initialize", let header = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = header
        }

        guard let reply = try MCPMessages.reply(to: id, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type")) else {
            throw MCPError.invalidResponse("no reply to \(method)")
        }

        if let error = reply["error"] as? [String: Any] {
            throw MCPError.server(error["message"] as? String ?? "the server refused \(method)")
        }

        return reply["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func post(_ message: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw MCPError.server("couldn't reach \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse("not HTTP") }
        if http.statusCode == 401 {
            throw MCPError.needsSignIn(challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
                ?? object?["error_description"] as? String ?? object?["message"] as? String ?? ""
            throw MCPError.http(status: http.statusCode, message: message)
        }

        return (data, http)
    }
}
