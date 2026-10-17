/// `{{name}}` and `{{name.field}}` substitution. Deliberately not a language:
/// no expressions, no functions, nothing executed. Unknown names render empty.
enum Template {
    static func references(in text: String) -> [String] {
        var rest = Substring(text), result: [String] = []
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            result.append(rest[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespaces))
            rest = rest[close.upperBound...]
        }
        return result
    }

    /// `escape` adapts each substituted value to where it lands (a URL, a JSON
    /// body); the template's own text is left as written. `text` turns a
    /// value into text: as it reads in a sentence, or as a model reads it.
    static func render(
        _ template: String,
        _ resolve: (String) -> Value?,
        escape: (String) -> String = { $0 },
        text: (Value) -> String = Template.inlineText
    ) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                output += rest[open.lowerBound...]
                return output
            }
            let reference = rest[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespaces)
            output += escape(resolve(reference).map(text) ?? "")
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    /// A value as it reads inside a sentence: a list of words joined with
    /// commas, everything else as its plain text.
    static func inlineText(_ value: Value) -> String {
        if case let .list(items) = value, items.allSatisfy({ if case .list = $0 { false } else if case .dictionary = $0 { false } else { true } }) {
            return items.map(\.textValue).joined(separator: ", ")
        }
        return value.textValue
    }
}
