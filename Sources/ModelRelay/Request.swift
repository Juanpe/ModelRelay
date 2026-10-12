import Foundation

/// An HTTP call described as data. Every part is a template: earlier results
/// fill it with `{{step.field}}`, secrets with `{{secret.NAME}}`. Values are
/// escaped for where they land (percent-encoded in the URL, JSON-escaped in a
/// JSON body), so a model's output can fill a field but never reshape the call.
public struct HTTPRequest: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"

        /// Calls that change something on the other side. They never run
        /// unless the runner's `WritePolicy` allows them, and are never retried.
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

    public var method: Method
    public var url: String
    public var headers: [Header]
    public var body: String?

    public init(_ method: Method = .get, url: String, headers: [Header] = [], body: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
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
        for header in headers { text += "\n\(header.name): \(header.value)" }
        if let body, let string = String(data: body, encoding: .utf8) { text += "\n\n\(string)" }
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "•••")
        }
        return text
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
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

extension Value {
    /// A value from a JSON response body, or nil if the body isn't JSON.
    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(jsonObject: object)
    }

    init(jsonObject object: Any) {
        switch object {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .text(string)
        case let array as [Any]:
            self = .list(array.map(Value.init(jsonObject:)))
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues(Value.init(jsonObject:)))
        default:
            self = .null
        }
    }
}

enum RequestBuilder {
    static let maxResponseBytes = 2_000_000

    /// Names used as `{{secret.NAME}}` anywhere in the request.
    static func secretNames(in request: HTTPRequest) -> Set<String> {
        let parts = [request.url, request.body ?? ""] + request.headers.map(\.value)
        var names = Set<String>()
        for part in parts {
            var rest = Substring(part)
            while let open = rest.range(of: "{{") {
                guard let close = rest[open.upperBound...].range(of: "}}") else { break }
                let reference = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                if reference.hasPrefix("secret.") { names.insert(String(reference.dropFirst("secret.".count))) }
                rest = rest[close.upperBound...]
            }
        }
        return names
    }

    static func prepare(_ request: HTTPRequest, secrets: [String: String],
                        resolve: (String) -> Value?) throws -> PreparedRequest {
        func lookup(_ reference: String) -> Value? {
            if reference.hasPrefix("secret.") {
                return secrets[String(reference.dropFirst("secret.".count))].map(Value.text)
            }
            return resolve(reference)
        }

        let urlText = Template.render(request.url, lookup, escape: Self.percentEncode)
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw InvalidRequest(reason: "“\(request.url)” isn't a valid http or https URL")
        }
        let headers = request.headers.map { header in
            // Header values can't hold line breaks: they would start a new header.
            HTTPRequest.Header(Self.singleLine(header.name),
                               Self.singleLine(Template.render(header.value, lookup)))
        }
        let body = request.body.map { template -> Data in
            let isJSON = template.trimmingCharacters(in: .whitespacesAndNewlines).first.map { $0 == "{" || $0 == "[" } ?? false
            return Data(Template.render(template, lookup, escape: isJSON ? Self.jsonEscape : { $0 }).utf8)
        }
        return PreparedRequest(method: request.method, url: url, headers: headers, body: body,
                               secrets: Array(secrets.values))
    }

    /// Turns a response into a step value: JSON becomes fields, anything else text.
    static func value(from response: HTTPResponse) throws -> Value {
        guard (200..<300).contains(response.status) else {
            throw InvalidOutput(reason: "The server answered HTTP \(response.status)")
        }
        guard response.body.count <= maxResponseBytes else {
            throw InvalidOutput(reason: "The response is larger than \(maxResponseBytes / 1_000_000) MB")
        }
        if response.body.isEmpty { return .null }
        return Value(json: response.body) ?? .text(String(decoding: response.body, as: UTF8.self))
    }

    static func percentEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:@;")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func jsonEscape(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let quoted = String(data: data, encoding: .utf8) else { return "" }
        return String(quoted.dropFirst().dropLast())
    }

    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

struct InvalidRequest: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}
