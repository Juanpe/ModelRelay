import Foundation
import AnyLanguageModel
import ImageIO
import UniformTypeIdentifiers

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
        case .text(let text): text
        case .number(let number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let bool): bool ? "true" : "false"
        case .list(let items): items.map(\.textValue).joined(separator: "\n")
        case .dictionary(let fields):
            fields.keys.sorted().map { "\($0): \(fields[$0]?.textValue ?? "")" }.joined(separator: "\n")
        case .image(let image): image.text ?? ""
        }
    }

    /// How a model reads a value: lists and fields as JSON, which keeps
    /// their structure; everything else as its text.
    var modelText: String {
        switch self {
        case .list, .dictionary:
            guard let data = try? JSONSerialization.data(withJSONObject: jsonObject,
                                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
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

/// An image's bytes and type, with any text that came along with it.
public struct ImageValue: Codable, Sendable, Hashable {
    public var data: Data
    /// A MIME type, like `image/jpeg`.
    public var contentType: String
    /// Words that came with the image, such as a shortcut's text input.
    public var text: String?

    public init(data: Data, contentType: String, text: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.text = text
    }
}

/// What a Read Text in Image step asks for and records.
enum ImageReading {
    static let defaultInstruction = "Write out all the text in the image exactly as it appears, keeping its line breaks. Reply with the text only."

    /// "Image: JPEG, 1.2 MB", for the step's record instead of the bytes.
    static func describe(_ image: ImageValue) -> String {
        let format = image.contentType.split(separator: "/").last.map { $0.uppercased() } ?? "image"
        return "Image: \(format), \(Int64(image.data.count).formatted(.byteCount(style: .file)))"
    }
}

/// Opens images for models and encodes them for chat APIs.
package enum ImageCoding {
    /// The image upright (its orientation applied) and at most `maxPixels`
    /// on its long side; smaller images keep their size.
    package static func picture(from data: Data, maxPixels: Int = 4096) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG (PNG when it has transparency, which JPEG would turn black),
    /// upright and at most `maxPixels` on its long side, as chat APIs want it.
    package static func encoded(_ image: CGImage, orientation: CGImagePropertyOrientation = .up,
                                maxPixels: Int = 2048) -> (data: Data, contentType: String)? {
        var image = image
        if orientation != .up {
            // Apply the orientation by writing it out and reading it back.
            guard let tagged = write(image, as: .png, properties: [kCGImagePropertyOrientation: orientation.rawValue]),
                  let upright = picture(from: tagged, maxPixels: maxPixels) else { return nil }
            image = upright
        }
        let transparent = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type: UTType = transparent ? .png : .jpeg
        let data = write(image, as: type, properties: [kCGImageDestinationImageMaxPixelSize: maxPixels,
                                                       kCGImageDestinationLossyCompressionQuality: 0.85])
        return data.map { ($0, type.preferredMIMEType ?? "image/jpeg") }
    }

    private static func write(_ image: CGImage, as type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
