import Foundation

enum RequestBuilder {
    static let maxResponseBytes = 2_000_000

    /// A server/error can echo a URL-encoded or JSON-escaped credential too.
    static func redact(_ text: String, secrets: [String]) -> String {
        let variants = Set(secrets.filter { !$0.isEmpty }.flatMap { [$0, percentEncode($0), secretEncode($0), jsonEscape($0)] })
        return variants.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "•••")
        }
    }

    /// Names used as `{{secret.NAME}}` anywhere in the request.
    static func secretNames(in request: HTTPRequest) -> Set<String> {
        let parts = [request.url, request.body ?? ""] + request.headers.map(\.value)
        var names = Set<String>()

        for part in parts {
            var rest = Substring(part)
            while let open = rest.range(of: "{{") {
                guard let close = rest[open.upperBound...].range(of: "}}") else { break }
                let reference = rest[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespaces)
                if reference.hasPrefix("secret.") { names.insert(String(reference.dropFirst("secret.".count))) }
                rest = rest[close.upperBound...]
            }
        }

        return names
    }

    static func prepare(
        _ request: HTTPRequest,
        secrets: [String: String],
        resolve: (String) -> Value?
    ) throws -> PreparedRequest {
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
        let urlText: String = if let reference = Self.wholeReference(urlTemplate), !reference.hasPrefix("secret.") {
            lookup(reference)?.textValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            Template.render(urlTemplate, lookup, escape: Self.percentEncode)
        }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else {
            throw InvalidRequest(reason: "“\(request.url)” isn't a valid http or https URL")
        }

        let headers = request.headers.map { header in
            // Header values can't hold line breaks: they would start a new header.
            HTTPRequest.Header(
                Self.singleLine(header.name),
                Self.singleLine(Template.render(header.value, lookup))
            )
        }
        let body = request.body.map { template -> Data in
            let isJSON = template.trimmingCharacters(in: .whitespacesAndNewlines).first.map { $0 == "{" || $0 == "[" } ?? false
            return Data((isJSON ? Self.renderJSON(template, lookup) : Template.render(template, lookup)).utf8)
        }

        return PreparedRequest(
            method: request.method,
            url: url,
            headers: headers,
            body: body,
            secrets: Array(secrets.values)
        )
    }

    /// `NAME` when the template is exactly `{{NAME}}`.
    static func wholeReference(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.count > 4 else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        guard !inner.contains("{"), !inner.contains("}") else { return nil }
        return inner.trimmingCharacters(in: .whitespaces)
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
               let close = template[template.index(index, offsetBy: 2)...].range(of: "}}")
            {
                let reference = template[template.index(index, offsetBy: 2) ..< close.lowerBound]
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
        if case let .text(text) = value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return isJSONScalar(trimmed) ? trimmed : "\"" + jsonEscape(text) + "\""
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value.jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else {
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
