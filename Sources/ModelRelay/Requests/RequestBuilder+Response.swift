import Foundation

extension RequestBuilder {
    /// Turns a response into a step value: JSON becomes fields, anything else
    /// text; read as a page, the page's readable text.
    static func value(from response: HTTPResponse, reading: HTTPRequest.Reading? = nil) throws -> Value {
        try response.validateSuccess(or: HTTPResponseFailure(
            status: response.status,
            description: "The server answered HTTP \(response.status)" + (errorDetail(response.body).map { ": \($0)" } ?? "")
        ))
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
        if let object = HTTPResponse.jsonObject(from: body) {
            return HTTPResponse.errorMessage(in: object).flatMap(short)
        }
        let text = String(decoding: body, as: UTF8.self)
        // An HTML error page says nothing useful in its first characters.
        return text.lowercased().contains("<html") ? nil : short(text)
    }
}
