import Foundation
import ModelRelay

/// MCP tool descriptions and results as ModelRelay values.
enum MCPSchema {
    static func tool(from item: [String: Any]) -> ServerTool? {
        guard let name = item["name"] as? String, !name.isEmpty else { return nil }

        let schema = item["inputSchema"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let properties = schema["properties"] as? [String: Any] ?? [:]
        // Required first, then by name: the order models and forms read.
        let names = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }

        let parameters = names.map { name -> Field in
            let property = properties[name] as? [String: Any] ?? [:]
            var description = property["description"] as? String
            let kind = self.kind(of: property)
            if kind == .text, isStructured(property) {
                description = [description, "Write it as JSON."].compactMap { $0 }.joined(separator: " ")
            }

            return Field(name, kind, description: description)
        }

        let annotations = item["annotations"] as? [String: Any] ?? [:]
        return ServerTool(
            name: name,
            title: item["title"] as? String ?? annotations["title"] as? String,
            description: item["description"] as? String ?? "",
            parameters: parameters,
            required: required.filter(properties.keys.contains),
            changesSomething: annotations["readOnlyHint"] as? Bool != true
        )
    }

    private static func type(of property: [String: Any]) -> String? {
        if let type = property["type"] as? String { return type }
        return (property["type"] as? [String])?.first { $0 != "null" }
    }

    private static func isStructured(_ property: [String: Any]) -> Bool {
        let type = type(of: property)
        return type == "object" || (type == nil && property["enum"] == nil)
    }

    static func kind(of property: [String: Any]) -> Field.Kind {
        if let options = property["enum"] as? [String], !options.isEmpty { return .choice(options) }
        switch type(of: property) {
        case "number", "integer": return .number
        case "boolean": return .bool
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            let item = kind(of: items)
            // Lists of objects read as text (JSON); lists of lists aren't offered.
            if case .list = item { return .text }
            return isStructured(items) ? .text : .list(item)
        default: return .text
        }
    }

    /// Structured content when the server gives it; otherwise its text,
    /// read as JSON when it is.
    static func value(fromCallResult result: [String: Any]) -> Value {
        if let structured = result["structuredContent"] { return Value(jsonObject: structured) }
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            switch item["type"] as? String {
            case "text": item["text"] as? String
            case "resource": (item["resource"] as? [String: Any])?["text"] as? String
            default: nil
            }
        }
        let text = texts.joined(separator: "\n")
        if texts.count == 1, let data = text.data(using: .utf8), let json = Value(json: data),
           case .dictionary = json { return json }
        if texts.count == 1, let data = text.data(using: .utf8), let json = Value(json: data),
           case .list = json { return json }
        return .text(text)
    }
}
