import Foundation

/// The readable text of a web page: its title and the words of its article
/// (or main content, or body), without scripts, styles, menus or markup.
/// Only ever text: nothing in the page is run.
enum PageText {
    /// Text beyond this is cut: enough for an article, not for a whole site.
    static let maxCharacters = 30000

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
        text = text.replacingOccurrences(
            of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/blockquote)[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"\h+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removing(_ tag: String, from html: String) -> String {
        html.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
    }

    private static func inner(_ tag: String, of html: String) -> String? {
        guard let range = html.range(of: "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>", options: .regularExpression) else { return nil }
        let match = String(html[range])
        guard let open = match.firstIndex(of: ">"), let close = match.range(of: "</", options: .backwards) else { return nil }
        return String(match[match.index(after: open) ..< close.lowerBound])
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in named {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        while let range = text.range(of: #"&#[xX]?[0-9a-fA-F]+;"#, options: .regularExpression) {
            let code = text[range].dropFirst(2).dropLast()
            let value = code.first == "x" || code.first == "X" ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            text.replaceSubrange(range, with: value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return text
    }
}
