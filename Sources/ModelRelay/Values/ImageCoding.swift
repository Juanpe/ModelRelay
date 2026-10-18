import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    package static func encoded(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        maxPixels: Int = 2048
    ) -> (data: Data, contentType: String)? {
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
