/// `{{name}}` and `{{name.field}}` substitution. Deliberately not a language:
/// no expressions, no functions, nothing executed. Unknown names render empty.
enum Template {
    /// `escape` adapts each substituted value to where it lands (a URL, a JSON
    /// body); the template's own text is left as written.
    static func render(_ template: String, _ resolve: (String) -> Value?,
                       escape: (String) -> String = { $0 }) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                output += rest[open.lowerBound...]
                return output
            }
            let reference = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            output += escape(resolve(reference).map(inlineText) ?? "")
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    /// A value as it reads inside a sentence: a list of words joined with
    /// commas, everything else as its plain text.
    private static func inlineText(_ value: Value) -> String {
        if case .list(let items) = value, items.allSatisfy({ if case .list = $0 { false } else if case .dictionary = $0 { false } else { true } }) {
            return items.map(\.textValue).joined(separator: ", ")
        }
        return value.textValue
    }
}
