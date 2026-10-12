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
            output += escape(resolve(reference)?.textValue ?? "")
            rest = rest[close.upperBound...]
        }
        return output + rest
    }
}
