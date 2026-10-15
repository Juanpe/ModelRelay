import CryptoKit
import Foundation

/// OAuth building blocks for MCP servers: discover endpoints, optionally
/// register a client, create a PKCE attempt, exchange a code and refresh.
/// The host presents and validates the redirect and securely stores tokens.
/// These helpers are not a complete OAuth client: issuer validation and
/// Client ID Metadata Documents are not implemented. A host can instead
/// supply tokens from its own OAuth client through `MCPConnector.accessToken`.
public enum MCPSignIn {
    /// Where to sign in, found from the MCP server.
    public struct Plan: Codable, Sendable, Hashable {
        public var resource: String
        public var authorizationEndpoint: URL
        public var tokenEndpoint: URL
        public var registrationEndpoint: URL?
        public var scopes: [String]

        /// Uses endpoints supplied by the host, for example after discovery
        /// through its own OAuth client. The host must trust these endpoints.
        public init(resource: String, authorizationEndpoint: URL, tokenEndpoint: URL,
                    registrationEndpoint: URL? = nil, scopes: [String] = []) {
            self.resource = resource
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.registrationEndpoint = registrationEndpoint
            self.scopes = scopes
        }
    }

    /// This app, as registered with the authorization server.
    public struct Client: Codable, Sendable, Hashable {
        public var id: String
        public var secret: String?

        public init(id: String, secret: String? = nil) {
            self.id = id
            self.secret = secret
        }
    }

    public struct Tokens: Codable, Sendable, Hashable {
        public var access: String
        public var refresh: String?
        public var expiresAt: Date?

        /// Restores credentials from host-owned secure storage or an external
        /// OAuth client. ModelRelay does not persist or log these values.
        public init(access: String, refresh: String? = nil, expiresAt: Date? = nil) {
            self.access = access
            self.refresh = refresh
            self.expiresAt = expiresAt
        }

        /// Expired, or about to: refresh a minute early.
        public var isExpired: Bool { expiresAt.map { $0 < Date().addingTimeInterval(60) } ?? false }
    }

    /// One sign-in attempt: the page to open and what proves it's ours.
    public struct Attempt: Sendable {
        public var url: URL
        let verifier: String
        let state: String
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case noAuthorizationServer
        case cantRegister
        case cancelledOrWrongState
        case denied(String)
        case tokenRefused(String)

        public var errorDescription: String? {
            switch self {
            case .noAuthorizationServer: "the server doesn't say where to sign in"
            case .cantRegister: "the server doesn't let apps register; it needs a client ID"
            case .cancelledOrWrongState: "the sign-in didn't come back from this app's request"
            case .denied(let reason): "sign-in was refused: \(reason)"
            case .tokenRefused(let reason): "the server didn't give a token: \(reason)"
            }
        }
    }

    // MARK: - Discovery

    /// Reads the server's protected-resource metadata (from its 401
    /// challenge, or the well-known address) and then its authorization
    /// server's metadata. Servers without either get the defaults of the
    /// first MCP spec: the server's own origin with /authorize and /token.
    public static func discover(server: URL, challenge: String? = nil,
                                session: URLSession = URLSession(configuration: .ephemeral)) async throws -> Plan {
        var issuer = origin(of: server)
        var scopes: [String] = []
        let metadataURLs = [challenge.flatMap(resourceMetadataURL(in:)), wellKnown("oauth-protected-resource", for: server),
                            wellKnown("oauth-protected-resource", for: origin(of: server))].compactMap { $0 }
        for url in metadataURLs {
            if let metadata = try? await getJSON(url, session: session),
               let first = (metadata["authorization_servers"] as? [String])?.first, let found = URL(string: first) {
                issuer = found
                scopes = metadata["scopes_supported"] as? [String] ?? []
                break
            }
        }
        for url in [wellKnown("oauth-authorization-server", for: issuer), wellKnown("openid-configuration", for: issuer)] {
            if let metadata = try? await getJSON(url, session: session),
               let authorize = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
               let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)) {
                return Plan(resource: server.absoluteString, authorizationEndpoint: authorize, tokenEndpoint: token,
                            registrationEndpoint: (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                            scopes: scopes)
            }
        }
        // The 2025-03-26 defaults.
        let base = origin(of: server)
        return Plan(resource: server.absoluteString, authorizationEndpoint: base.appending(path: "authorize"),
                    tokenEndpoint: base.appending(path: "token"), registrationEndpoint: base.appending(path: "register"),
                    scopes: scopes)
    }

    /// Registers this app (dynamic client registration). Public client: no
    /// secret, PKCE instead.
    public static func register(_ plan: Plan, redirectURI: String, clientName: String,
                                session: URLSession = URLSession(configuration: .ephemeral)) async throws -> Client {
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
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["client_id"] as? String else { throw Failure.cantRegister }
        return Client(id: id, secret: object["client_secret"] as? String)
    }

    // MARK: - Signing in

    /// The page to open for one sign-in, with a fresh PKCE verifier and state.
    public static func start(_ plan: Plan, client: Client, redirectURI: String) -> Attempt {
        let verifier = randomString(bytes: 32)
        let state = randomString(bytes: 16)
        var components = URLComponents(url: plan.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: plan.resource),
        ]
        if !plan.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: plan.scopes.joined(separator: " "))) }
        components.queryItems = items
        return Attempt(url: components.url!, verifier: verifier, state: state)
    }

    /// Reads the page's redirect back to the app and trades its code for tokens.
    public static func finish(_ attempt: Attempt, callback: URL, plan: Plan, client: Client, redirectURI: String,
                              session: URLSession = URLSession(configuration: .ephemeral)) async throws -> Tokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") { throw Failure.denied(item("error_description") ?? error) }
        guard item("state") == attempt.state, let code = item("code") else { throw Failure.cancelledOrWrongState }
        return try await token(plan, client: client, session: session, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "code_verifier": attempt.verifier,
        ])
    }

    /// New tokens from a refresh token. Servers that don't send a new
    /// refresh token keep the old one valid.
    public static func refresh(_ tokens: Tokens, plan: Plan, client: Client,
                               session: URLSession = URLSession(configuration: .ephemeral)) async throws -> Tokens {
        guard let refreshToken = tokens.refresh else { throw Failure.tokenRefused("there's no refresh token") }
        var refreshed = try await token(plan, client: client, session: session, form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ])
        if refreshed.refresh == nil { refreshed.refresh = refreshToken }
        return refreshed
    }

    private static func token(_ plan: Plan, client: Client, session: URLSession, form: [String: String]) async throws -> Tokens {
        var fields = form
        fields["client_id"] = client.id
        fields["resource"] = plan.resource
        if let secret = client.secret { fields["client_secret"] = secret }
        var request = URLRequest(url: plan.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let access = object["access_token"] as? String else {
            throw Failure.tokenRefused(object["error_description"] as? String ?? object["error"] as? String ?? "no access token")
        }
        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue
        return Tokens(access: access, refresh: object["refresh_token"] as? String,
                      expiresAt: lifetime.map { Date().addingTimeInterval($0) })
    }

    // MARK: - Helpers

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

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomString(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func getJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.noAuthorizationServer
        }
        return object
    }
}
