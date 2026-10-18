import Foundation

extension Value {
    /// A value from a JSON response body, or nil if the body isn't JSON.
    package init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(jsonObject: object)
    }

    package init(jsonObject object: Any) {
        switch object {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .text(string)
        case let array as [Any]:
            self = .list(array.map(Value.init(jsonObject:)))
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues(Value.init(jsonObject:)))
        default:
            self = .null
        }
    }
}

extension Value {
    /// The value as `JSONSerialization` objects (an image as its text).
    package var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case let .text(text): text
        // Through the shortest description, so 4.5 + 3.8 is sent as 8.3,
        // not 8.3000000000000007.
        case let .number(number): NSDecimalNumber(string: Value.number(number).textValue)
        case let .bool(bool): bool
        case let .list(items): items.map(\.jsonObject)
        case let .dictionary(fields): fields.mapValues(\.jsonObject)
        case let .image(image): image.text ?? ""
        }
    }
}

extension Value {
    /// Compact JSON, which models read more reliably than `textValue` for nested data.
    package var jsonText: String {
        guard let data = try? JSONEncoder().encode(JSONValue(self)),
              let text = String(data: data, encoding: .utf8) else { return textValue }
        return text
    }
}

/// Encodes a `Value` as plain JSON (not the tagged enum form).
private struct JSONValue: Encodable {
    let value: Value
    init(_ value: Value) { self.value = value }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case let .text(text): try container.encode(text)
        case let .number(number): try container.encode(number)
        case let .bool(bool): try container.encode(bool)
        case let .list(items): try container.encode(items.map(JSONValue.init))
        case let .dictionary(fields): try container.encode(fields.mapValues(JSONValue.init))
        // A tool or a JSON body gets the words, never the picture's bytes.
        case let .image(image): try container.encode(image.text ?? "")
        }
    }
}
