import Foundation

/// Identifies a model, resolved at run time by a `ModelCatalog`.
/// Examples: `apple.on-device`, `apple.private-cloud`, `mlx:mlx-community/Qwen3-1.7B-4bit`.
public struct ModelID: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Encoded as a plain string: `"model": "apple.on-device"`.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let appleOnDevice: ModelID = "apple.on-device"
    public static let applePrivateCloud: ModelID = "apple.private-cloud"
    /// Apple's on-device text recognition (Vision): reads the text in an
    /// image exactly as written, and nothing else. Only for `readImage` steps.
    public static let appleTextRecognition: ModelID = "apple.text-recognition"
}
