import Foundation

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
