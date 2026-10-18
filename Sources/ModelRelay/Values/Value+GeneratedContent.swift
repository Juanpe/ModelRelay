import AnyLanguageModel

extension Value {
    init(_ content: GeneratedContent) {
        switch content.kind {
        case .null: self = .null
        case let .bool(bool): self = .bool(bool)
        case let .number(number): self = .number(number)
        case let .string(string): self = .text(string)
        case let .array(items): self = .list(items.map(Value.init))
        case let .structure(properties, _): self = .dictionary(properties.mapValues(Value.init))
        @unknown default: self = .text(content.jsonString)
        }
    }
}
