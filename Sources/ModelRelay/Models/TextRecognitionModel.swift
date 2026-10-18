import AnyLanguageModel
import CoreText
import Foundation
import Vision

/// Apple's on-device text recognition (Vision) as a `LanguageModel`: it reads
/// the text in the prompt's image exactly as written and ignores the
/// instruction. Nothing leaves the device. Only `readImage` steps use it.
public struct TextRecognitionModel: LanguageModel, Hashable {
    public init() {}

    public typealias UnavailableReason = Never

    public func respond<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        guard type == String.self, session.tools.isEmpty,
              let image = Self.lastImage(in: session.transcript)
        else {
            throw InvalidOutput(reason: "Apple Text Recognition only reads the text in images. Use it in Read Text in Image")
        }
        try Task.checkCancellation()
        let lines = try await Recognition.recognize(image, orientation: .up)
        guard !lines.isEmpty else { throw InvalidOutput(reason: "There's no readable text in the image") }
        let raw = GeneratedContent(lines.joined(separator: "\n"))
        return try .init(content: Content(raw), rawContent: raw, transcriptEntries: [])
    }

    public func streamResponse<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(stream: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(
                        within: session,
                        to: prompt,
                        generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt,
                        options: options
                    )
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }

    private static func lastImage(in transcript: Transcript) -> CGImage? {
        for case let .prompt(prompt) in transcript.reversed() {
            for case let .image(image) in prompt.segments {
                if case let .data(data, _) = image.source { return ImageCoding.picture(from: data) }
            }
            return nil
        }
        return nil
    }

    /// Text recognition prepares its model the first time an app uses it,
    /// which can take a minute on a Mac. Call this in the background (say,
    /// when a workflow that uses it is opened) so the first run is quick.
    public static func prepare() async {
        let context = CGContext(
            data: nil,
            width: 160,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        guard let context else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let word = NSAttributedString(string: "Ready", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 12, y: 14)
        CTLineDraw(CTLineCreateWithAttributedString(word), context)
        guard let image = context.makeImage() else { return }
        _ = try? await Recognition.recognize(image, orientation: .up)
    }

    enum Recognition {
        static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [String] {
            var recognize = RecognizeTextRequest()
            recognize.recognitionLevel = .accurate
            recognize.usesLanguageCorrection = true
            recognize.automaticallyDetectsLanguage = true
            let pieces = try await recognize.perform(on: image, orientation: orientation).compactMap { observation in
                observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox.cgRect) }
            }
            return lines(pieces)
        }

        /// Text on the same row, like a receipt's item and its price, becomes
        /// one line read left to right; rows go top to bottom. Boxes are
        /// normalized with the origin at the bottom left.
        static func lines(_ pieces: [(text: String, box: CGRect)]) -> [String] {
            var rows: [[(text: String, box: CGRect)]] = []
            for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
                if let first = rows.last?.first,
                   abs(first.box.midY - piece.box.midY) < min(first.box.height, piece.box.height) / 2
                {
                    rows[rows.count - 1].append(piece)
                } else {
                    rows.append([piece])
                }
            }
            return rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
        }
    }
}
