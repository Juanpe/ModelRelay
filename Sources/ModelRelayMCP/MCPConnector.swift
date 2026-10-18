import Foundation
import ModelRelay

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
