import Foundation

/// A value flowing between steps. Typed so a workflow's output can be handed
/// to Shortcuts (or any caller) as text, a number or a dictionary.
public enum Value: Codable, Sendable, Hashable {
    case null
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([Value])
    case dictionary([String: Value])
    /// A picture, such as a photo or a screenshot a shortcut passes in. Steps
    /// that read images (Read Text in Image) send it to their model; in text
    /// it reads as the words that came with it, if any.
    case image(ImageValue)

    /// The value as plain text, for prompts and templates.
    public var textValue: String {
        switch self {
        case .null: ""
        case let .text(text): text
        case let .number(number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case let .bool(bool): bool ? "true" : "false"
        case let .list(items): items.map(\.textValue).joined(separator: "\n")
        case let .dictionary(fields):
            fields.keys.sorted().map { "\($0): \(fields[$0]?.textValue ?? "")" }.joined(separator: "\n")
        case let .image(image): image.text ?? ""
        }
    }

    /// How a model reads a value: lists and fields as JSON, which keeps
    /// their structure; everything else as its text.
    var modelText: String {
        switch self {
        case .list, .dictionary:
            guard let data = try? JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) else {
                return textValue
            }
            return String(decoding: data, as: UTF8.self)
        default:
            return textValue
        }
    }

    /// What kind of value this is, for failure reasons ("got text").
    var kindName: String {
        switch self {
        case .null: "nothing"
        case .text: "text"
        case .number: "a number"
        case .bool: "true or false"
        case .list: "a list"
        case .dictionary: "fields"
        case .image: "an image"
        }
    }

    /// A field of a dictionary, or nil.
    public subscript(field: String) -> Value? {
        if case let .dictionary(fields) = self { return fields[field] }
        return nil
    }
}
