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

    public init(_ method: Method = .get, url: String, headers: [Header] = [], body: String? = nil,
                reading: Reading? = nil) {
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
    package init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(jsonObject: object)
    }

    package init(jsonObject object: Any) {
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

extension Value {
    /// The value as `JSONSerialization` objects (an image as its text).
    package var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case .text(let text): text
        // Through the shortest description, so 4.5 + 3.8 is sent as 8.3,
        // not 8.3000000000000007.
        case .number(let number): NSDecimalNumber(string: Value.number(number).textValue)
        case .bool(let bool): bool
        case .list(let items): items.map(\.jsonObject)
        case .dictionary(let fields): fields.mapValues(\.jsonObject)
        case .image(let image): image.text ?? ""
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

        // Secrets are the person's own values (a Telegram bot token is
        // `123:ABC` inside the path), so they keep `:` in the URL; values from
        // earlier steps are fully encoded and can't change the URL's shape.
        var urlTemplate = request.url
        for (name, value) in secrets {
            urlTemplate = urlTemplate.replacingOccurrences(of: "{{secret.\(name)}}", with: Self.secretEncode(value))
        }
        // An address that is one value, like {{input}}, is that value as a
        // whole (a link passed in); it still has to be an http(s) URL below.
        // Inside a longer address, values are encoded and can't reshape it.
        let urlText: String
        if let reference = Self.wholeReference(urlTemplate), !reference.hasPrefix("secret.") {
            urlText = lookup(reference)?.textValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            urlText = Template.render(urlTemplate, lookup, escape: Self.percentEncode)
        }
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
            return Data((isJSON ? Self.renderJSON(template, lookup) : Template.render(template, lookup)).utf8)
        }
        return PreparedRequest(method: request.method, url: url, headers: headers, body: body,
                               secrets: Array(secrets.values))
    }

    /// `NAME` when the template is exactly `{{NAME}}`.
    static func wholeReference(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.count > 4 else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        guard !inner.contains("{"), !inner.contains("}") else { return nil }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    /// Turns a response into a step value: JSON becomes fields, anything else
    /// text; read as a page, the page's readable text.
    static func value(from response: HTTPResponse, reading: HTTPRequest.Reading? = nil) throws -> Value {
        guard (200..<300).contains(response.status) else {
            // The server's own explanation, when it gives one, says why.
            let detail = errorDetail(response.body).map { ": \($0)" } ?? ""
            throw InvalidOutput(reason: "The server answered HTTP \(response.status)\(detail)")
        }
        guard response.body.count <= maxResponseBytes else {
            throw InvalidOutput(reason: "The response is larger than \(maxResponseBytes / 1_000_000) MB")
        }
        if reading == .page {
            let text = PageText.extract(html: String(decoding: response.body, as: UTF8.self))
            guard !text.isEmpty else { throw InvalidOutput(reason: "The page has no readable text") }
            return .text(text.count > PageText.maxCharacters ? String(text.prefix(PageText.maxCharacters)) + "…" : text)
        }
        if response.body.isEmpty { return .null }
        return Value(json: response.body) ?? .text(String(decoding: response.body, as: UTF8.self))
    }

    /// A short reason from an error response: a JSON `description`, `message`
    /// or `error` field (Telegram, most APIs), or the start of a text body.
    static func errorDetail(_ body: Data) -> String? {
        let limit = 300
        func short(_ text: String) -> String? {
            let line = singleLine(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        guard !body.isEmpty, body.count <= maxResponseBytes else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["description", "message", "error_description", "detail"] {
                if let text = object[key] as? String { return short(text) }
            }
            if let text = object["error"] as? String { return short(text) }
            if let nested = object["error"] as? [String: Any], let text = nested["message"] as? String { return short(text) }
            return nil
        }
        let text = String(decoding: body, as: UTF8.self)
        // An HTML error page says nothing useful in its first characters.
        return text.lowercased().contains("<html") ? nil : short(text)
    }

    static func percentEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:@;")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func secretEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&=+@;")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// A JSON body. Inside a string, a value is escaped text. Standing as a
    /// value of its own (`"expense": {{expense}}`), it's inserted as JSON:
    /// fields stay an object, lists an array, numbers numbers. Text there
    /// becomes a JSON string, unless it already is a JSON number, `true`,
    /// `false` or `null` (`"chat_id": {{secret.CHAT}}`). Either way a value
    /// is encoded whole and can't change the body around it.
    static func renderJSON(_ template: String, _ lookup: (String) -> Value?) -> String {
        var output = ""
        var inString = false
        var escaped = false
        var index = template.startIndex
        while index < template.endIndex {
            if template[index...].hasPrefix("{{"),
               let close = template[template.index(index, offsetBy: 2)...].range(of: "}}") {
                let reference = template[template.index(index, offsetBy: 2)..<close.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                let value = lookup(reference)
                output += inString ? jsonEscape(value.map(Template.inlineText) ?? "") : jsonLiteral(value)
                index = close.upperBound
                continue
            }
            let character = template[index]
            output.append(character)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            }
            index = template.index(after: index)
        }
        return output
    }

    static func jsonLiteral(_ value: Value?) -> String {
        guard let value else { return "null" }
        if case .text(let text) = value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return isJSONScalar(trimmed) ? trimmed : "\"" + jsonEscape(text) + "\""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value.jsonObject,
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isJSONScalar(_ text: String) -> Bool {
        ["true", "false", "null"].contains(text)
            || text.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
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

/// The readable text of a web page: its title and the words of its article
/// (or main content, or body), without scripts, styles, menus or markup.
/// Only ever text: nothing in the page is run.
enum PageText {
    /// Text beyond this is cut: enough for an article, not for a whole site.
    static let maxCharacters = 30_000

    static func extract(html: String) -> String {
        var page = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe"] {
            page = removing(tag, from: page)
        }
        let title = inner("title", of: page).map(plain)
        var content = inner("article", of: page) ?? inner("main", of: page) ?? inner("body", of: page) ?? page
        for tag in ["nav", "header", "footer", "aside", "form"] {
            content = removing(tag, from: content)
        }
        let text = plain(content)
        guard let title, !title.isEmpty, !text.hasPrefix(title) else { return text }
        return "\(title)\n\n\(text)"
    }

    /// Markup to plain text: block ends become line breaks, tags go, common
    /// entities are decoded and blank runs collapse.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/blockquote)[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"\h+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removing(_ tag: String, from html: String) -> String {
        html.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
    }

    private static func inner(_ tag: String, of html: String) -> String? {
        guard let range = html.range(of: "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>", options: .regularExpression) else { return nil }
        let match = String(html[range])
        guard let open = match.firstIndex(of: ">"), let close = match.range(of: "</", options: .backwards) else { return nil }
        return String(match[match.index(after: open)..<close.lowerBound])
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in named { text = text.replacingOccurrences(of: entity, with: character) }
        while let range = text.range(of: #"&#[xX]?[0-9a-fA-F]+;"#, options: .regularExpression) {
            let code = text[range].dropFirst(2).dropLast()
            let value = code.first == "x" || code.first == "X" ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            text.replaceSubrange(range, with: value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return text
    }
}
