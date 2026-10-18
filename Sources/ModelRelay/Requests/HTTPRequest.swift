import Foundation

/// An HTTP call described as data. Every part is a template: earlier results
/// fill it with `{{step.field}}`, secrets with `{{secret.NAME}}`. Values are
/// escaped for where they land (percent-encoded in the URL, JSON-escaped in a
/// JSON body), so a model's output can fill a field but never reshape the call.
public struct HTTPRequest: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"

        /// Calls that change something on the other side. They never run
        /// unless the executor's `WritePolicy` allows them, and are never retried.
        public var isWrite: Bool { self != .get }
    }

    public struct Header: Codable, Sendable, Hashable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// How to read the reply. Nil reads JSON as fields and anything else as
    /// text; `.page` reads a web page as its title and readable text.
    public enum Reading: String, Codable, Sendable {
        case page
    }

    public var method: Method
    public var url: String
    public var headers: [Header]
    public var body: String?
    public var reading: Reading?

    public init(
        _ method: Method = .get,
        url: String,
        headers: [Header] = [],
        body: String? = nil,
        reading: Reading? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.reading = reading
    }
}

/// A request with every template filled in, ready to send.
public struct PreparedRequest: Sendable, CustomStringConvertible {
    public var method: HTTPRequest.Method
    public var url: URL
    public var headers: [HTTPRequest.Header]
    public var body: Data?
    /// Secret values used in this request. `description` hides them, so a
    /// confirmation prompt or a log never shows a key.
    let secrets: [String]

    public var description: String {
        var text = "\(method.rawValue) \(url.absoluteString)"
        for header in headers {
            text += "\n\(header.name): \(header.value)"
        }
        if let body, let string = String(data: body, encoding: .utf8) { text += "\n\n\(string)" }
        return RequestBuilder.redact(text, secrets: secrets)
    }
}

/// Sends prepared requests. ModelRelay has no network code of its own; apps
/// pass `URLSessionRequestPerformer` from ModelRelayHTTP, tests pass a fake.
public protocol RequestPerformer: Sendable {
    func perform(_ request: PreparedRequest) async throws -> HTTPResponse
}

/// Looks up secrets by name, for example from the Keychain. Only request
/// steps can read secrets; prompts never see them.
public protocol SecretProvider: Sendable {
    func secret(named name: String) async throws -> String?
}

/// Whether request steps that change something (POST, PUT, PATCH, DELETE) may run.
public enum WritePolicy: Sendable {
    case deny
    case allow
    /// Ask first; the closure sees the request with secrets hidden.
    case ask(@Sendable (PreparedRequest) async -> Bool)
}

/// The raw server response error, accessible only by explicitly inspecting a
/// failure's rootCause. Its description may echo credentials; prefer failure.info
/// for diagnostics, where request secrets have been redacted.
public struct HTTPResponseFailure: Error, Sendable, CustomStringConvertible, WorkflowFailureClassifiable {
    public let status: Int
    public let description: String
    public var workflowFailureCategory: WorkflowFailureCategory {
        status == 401 ? .authenticationRequired : status == 403 ? .permissionDenied : .requestRejected
    }
}
