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
        public init(
            resource: String,
            authorizationEndpoint: URL,
            tokenEndpoint: URL,
            registrationEndpoint: URL? = nil,
            scopes: [String] = []
        ) {
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
            case let .denied(reason): "sign-in was refused: \(reason)"
            case let .tokenRefused(reason): "the server didn't give a token: \(reason)"
            }
        }
    }
}
