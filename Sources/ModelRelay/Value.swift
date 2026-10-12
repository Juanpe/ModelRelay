import Foundation
import FoundationModels

/// A value flowing between steps. Typed so a workflow's output can be handed
/// to Shortcuts (or any caller) as text, a number or a dictionary.
public enum Value: Codable, Sendable, Hashable {
    case null
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([Value])
    case dictionary([String: Value])

    /// The value as plain text, for prompts and templates.
    public var textValue: String {
        switch self {
        case .null: ""
        case .text(let text): text
        case .number(let number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let bool): bool ? "true" : "false"
        case .list(let items): items.map(\.textValue).joined(separator: "\n")
        case .dictionary(let fields):
            fields.keys.sorted().map { "\($0): \(fields[$0]?.textValue ?? "")" }.joined(separator: "\n")
        }
    }

    /// A field of a dictionary, or nil.
    public subscript(field: String) -> Value? {
        if case .dictionary(let fields) = self { return fields[field] }
        return nil
    }

    init(_ content: GeneratedContent) {
        switch content.kind {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = .number(number)
        case .string(let string): self = .text(string)
        case .array(let items): self = .list(items.map(Value.init))
        case .structure(let properties, _): self = .dictionary(properties.mapValues(Value.init))
        @unknown default: self = .text(content.jsonString)
        }
    }
}
