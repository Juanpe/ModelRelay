import Foundation
import ModelRelay

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
