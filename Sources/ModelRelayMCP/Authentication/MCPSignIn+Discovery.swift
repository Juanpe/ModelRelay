import Foundation

extension MCPSignIn {
    /// Reads the server's protected-resource metadata (from its 401
    /// challenge, or the well-known address) and then its authorization
    /// server's metadata. Servers without either get the defaults of the
    /// first MCP spec: the server's own origin with /authorize and /token.
    public static func discover(
        server: URL,
        challenge: String? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> Plan {
        var issuer = origin(of: server)
        var scopes: [String] = []
        let metadataURLs = [challenge.flatMap(resourceMetadataURL(in:)), wellKnown("oauth-protected-resource", for: server),
                            wellKnown("oauth-protected-resource", for: origin(of: server))].compactMap { $0 }

        for url in metadataURLs {
            if let metadata = try? await getJSON(url, session: session),
               let first = (metadata["authorization_servers"] as? [String])?.first, let found = URL(string: first)
            {
                issuer = found
                scopes = metadata["scopes_supported"] as? [String] ?? []
                break
            }
        }

        for url in [wellKnown("oauth-authorization-server", for: issuer), wellKnown("openid-configuration", for: issuer)] {
            if let metadata = try? await getJSON(url, session: session),
               let authorize = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
               let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:))
            {
                return Plan(
                    resource: server.absoluteString,
                    authorizationEndpoint: authorize,
                    tokenEndpoint: token,
                    registrationEndpoint: (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                    scopes: scopes
                )
            }
        }

        // The 2025-03-26 defaults.
        let base = origin(of: server)
        return Plan(
            resource: server.absoluteString,
            authorizationEndpoint: base.appending(path: "authorize"),
            tokenEndpoint: base.appending(path: "token"),
            registrationEndpoint: base.appending(path: "register"),
            scopes: scopes
        )
    }

    /// Registers this app (dynamic client registration). Public client: no
    /// secret, PKCE instead.
    public static func register(
        _ plan: Plan,
        redirectURI: String,
        clientName: String,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> Client {
        guard let endpoint = plan.registrationEndpoint else { throw Failure.cantRegister }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])

        let (data, response) = try await session.data(for: request)

        guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["client_id"] as? String else { throw Failure.cantRegister }

        return Client(id: id, secret: object["client_secret"] as? String)
    }

    /// `resource_metadata="…"` from a `WWW-Authenticate: Bearer` header.
    static func resourceMetadataURL(in challenge: String) -> URL? {
        guard let range = challenge.range(of: "resource_metadata=\"") else { return nil }
        let rest = challenge[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    /// RFC 8414 / 9728: the well-known path goes between the host and the path.
    static func wellKnown(_ name: String, for url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host()
        components.port = url.port
        let path = url.path(percentEncoded: true)
        components.percentEncodedPath = "/.well-known/\(name)" + (path == "/" ? "" : path)
        return components.url!
    }

    static func origin(of url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host()
        components.port = url.port
        return components.url!
    }

    private static func getJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.noAuthorizationServer
        }

        return object
    }
}
