import Foundation
import ModelRelay
import Synchronization

/// Connects tool sets that have a `ToolServer` to MCP servers over
/// Streamable HTTP. Header values may use `{{secret.NAME}}`; for servers the
/// person signs in to, `accessToken` returns the current OAuth token (the
/// app keeps and refreshes it).
public struct MCPConnector: ToolServerConnector {
    public var secrets: (any SecretProvider)?
    /// The host supplies a current token for this kit's server and account.
    /// Called for each connection; no automatic refresh or sign-in UI runs.
    public var accessToken: (@Sendable (ToolKit) async throws -> String?)?
    public var clientName: String
    var session: URLSession

    public init(
        secrets: (any SecretProvider)? = nil,
        accessToken: (@Sendable (ToolKit) async throws -> String?)? = nil,
        clientName: String = "ModelRelay",
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.secrets = secrets
        self.accessToken = accessToken
        self.clientName = clientName
        self.session = URLSession(configuration: configuration)
    }

    public func connect(to kit: ToolKit) async throws -> any ToolServerConnection {
        guard let server = kit.server, let url = URL(string: server.url),
              url.scheme == "https" || url.scheme == "http"
        else {
            throw MCPError.invalidAddress
        }

        var headers: [String: String] = [:]
        for header in server.headers {
            headers[header.name] = try await resolveSecrets(in: header.value)
        }

        if server.signsIn {
            guard let token = try await accessToken?(kit), !token.isEmpty else { throw MCPError.needsSignIn(challenge: nil) }
            headers["Authorization"] = "Bearer \(token)"
        }

        let client = MCPClient(url: url, headers: headers, clientName: clientName, session: session)
        try await client.start()
        return client
    }

    private func resolveSecrets(in text: String) async throws -> String {
        var result = ""
        var rest = Substring(text)

        while let open = rest.range(of: "{{secret."), let close = rest[open.upperBound...].range(of: "}}") {
            result += rest[..<open.lowerBound]
            let name = rest[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = try await secrets?.secret(named: name), !value.isEmpty else {
                throw RelayError.missingSecret(name, step: "")
            }

            result += value
            rest = rest[close.upperBound...]
        }

        return result + rest
    }
}

/// Why talking to an MCP server failed. Never contains a token.
public enum MCPError: Error, LocalizedError, Equatable, Sendable, WorkflowFailureClassifiable {
    case invalidAddress
    /// The server wants the person to sign in. `challenge` is its
    /// `WWW-Authenticate` header, which says where to start.
    case needsSignIn(challenge: String?)
    case http(status: Int, message: String)
    case server(String)
    case toolFailed(String)
    case invalidResponse(String)

    public var workflowFailureCategory: WorkflowFailureCategory {
        switch self {
        case .needsSignIn: .authenticationRequired
        case let .http(status, _): status == 401 ? .authenticationRequired : status == 403 ? .permissionDenied : .requestRejected
        case .invalidAddress: .validation
        case .invalidResponse: .invalidOutput
        default: .unknown
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "the server address isn't a web address"
        case .needsSignIn: "sign in to this server again"
        case let .http(status, message): message.isEmpty ? "the server answered HTTP \(status)" : "HTTP \(status): \(message)"
        case let .server(message): message
        case let .toolFailed(message): message
        case let .invalidResponse(message): "the server's reply couldn't be read (\(message))"
        }
    }
}

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

/// Reading MCP replies: JSON, or server-sent events that carry JSON.
enum MCPMessages {
    static func reply(to id: Int, in data: Data, contentType: String?) throws -> [String: Any]? {
        let messages: [Any]
        if contentType?.contains("text/event-stream") == true {
            messages = events(in: String(decoding: data, as: UTF8.self)).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            }
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw MCPError.invalidResponse("not JSON")
            }
            messages = (object as? [Any]) ?? [object]
        }

        return messages.compactMap { $0 as? [String: Any] }.first { message in
            (message["id"] as? Int) == id || (message["id"] as? String) == String(id)
        }
    }

    /// The data of each event: its `data:` lines joined.
    static func events(in stream: String) -> [String] {
        stream.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let data = block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { line in
                    let value = line.dropFirst("data:".count)
                    return value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)
                }

            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
    }
}

/// MCP tool descriptions and results as ModelRelay values.
enum MCPSchema {
    static func tool(from item: [String: Any]) -> ServerTool? {
        guard let name = item["name"] as? String, !name.isEmpty else { return nil }

        let schema = item["inputSchema"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let properties = schema["properties"] as? [String: Any] ?? [:]
        // Required first, then by name: the order models and forms read.
        let names = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }

        let parameters = names.map { name -> Field in
            let property = properties[name] as? [String: Any] ?? [:]
            var description = property["description"] as? String
            let kind = self.kind(of: property)
            if kind == .text, isStructured(property) {
                description = [description, "Write it as JSON."].compactMap { $0 }.joined(separator: " ")
            }

            return Field(name, kind, description: description)
        }

        let annotations = item["annotations"] as? [String: Any] ?? [:]
        return ServerTool(
            name: name,
            title: item["title"] as? String ?? annotations["title"] as? String,
            description: item["description"] as? String ?? "",
            parameters: parameters,
            required: required.filter(properties.keys.contains),
            changesSomething: annotations["readOnlyHint"] as? Bool != true
        )
    }

    private static func type(of property: [String: Any]) -> String? {
        if let type = property["type"] as? String { return type }
        return (property["type"] as? [String])?.first { $0 != "null" }
    }

    private static func isStructured(_ property: [String: Any]) -> Bool {
        let type = type(of: property)
        return type == "object" || (type == nil && property["enum"] == nil)
    }

    static func kind(of property: [String: Any]) -> Field.Kind {
        if let options = property["enum"] as? [String], !options.isEmpty { return .choice(options) }
        switch type(of: property) {
        case "number", "integer": return .number
        case "boolean": return .bool
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            let item = kind(of: items)
            // Lists of objects read as text (JSON); lists of lists aren't offered.
            if case .list = item { return .text }
            return isStructured(items) ? .text : .list(item)
        default: return .text
        }
    }

    /// Structured content when the server gives it; otherwise its text,
    /// read as JSON when it is.
    static func value(fromCallResult result: [String: Any]) -> Value {
        if let structured = result["structuredContent"] { return Value(jsonObject: structured) }
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            switch item["type"] as? String {
            case "text": item["text"] as? String
            case "resource": (item["resource"] as? [String: Any])?["text"] as? String
            default: nil
            }
        }
        let text = texts.joined(separator: "\n")
        if texts.count == 1, let data = text.data(using: .utf8), let json = Value(json: data),
           case .dictionary = json { return json }
        if texts.count == 1, let data = text.data(using: .utf8), let json = Value(json: data),
           case .list = json { return json }
        return .text(text)
    }
}
