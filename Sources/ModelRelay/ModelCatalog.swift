import CoreText
import Foundation
import AnyLanguageModel
import Vision

/// Resolves a `ModelID` to an AnyLanguageModel `LanguageModel`. Apps compose
/// catalogs: Apple's models are built in; MLX or cloud models are added by
/// registering a factory. ModelRelay itself never downloads or stores keys.
public struct ModelCatalog: Sendable {
    /// Resolved once per model ID and run, with concurrent loads coalesced.
    /// Return a shared backend for reuse across runs; session history stays run-local.
    public typealias Factory = @Sendable () async throws -> any LanguageModel

    /// Like Factory, resolved once per ID and run.
    public typealias DecisionFactory = @Sendable () async throws -> any DecisionModel

    private var imageModels: Set<ModelID> = [.appleTextRecognition]
    private var locations: [ModelID: ModelLocation] = [.appleOnDevice: .local, .appleTextRecognition: .local, .applePrivateCloud: .remote]
    private var factories: [ModelID: Factory]
    private var decisionFactories: [ModelID: DecisionFactory] = [:]

    public init() {
        if SystemLanguageModel.default.supportsImageInput { imageModels.insert(.appleOnDevice) }
        if PrivateCloudComputeLanguageModel.default.supportsImageInput { imageModels.insert(.applePrivateCloud) }
        factories = [
            .appleOnDevice: { SystemLanguageModel.default },
            .applePrivateCloud: { PrivateCloudComputeLanguageModel() },
            .appleTextRecognition: { TextRecognitionModel() },
        ]
    }

    /// Registers a native provider. Enable `supportsImages` only for a model
    /// that accepts images; AnyLanguageModel has no universal vision capability.
    public mutating func register(_ id: ModelID, supportsImages: Bool = false, location: ModelLocation = .unspecified, factory: @escaping Factory) {
        factories[id] = factory
        decisionFactories[id] = nil
        locations[id] = location
        if supportsImages { imageModels.insert(id) } else { imageModels.remove(id) }
    }

    public func registering(_ id: ModelID, supportsImages: Bool = false, location: ModelLocation = .unspecified, factory: @escaping Factory) -> ModelCatalog {
        var copy = self
        copy.register(id, supportsImages: supportsImages, location: location, factory: factory)
        return copy
    }

    /// Adds a model for decide steps (it answers questions; it doesn't write text).
    public mutating func register(decisions id: ModelID, location: ModelLocation = .unspecified, factory: @escaping DecisionFactory) {
        decisionFactories[id] = factory
        factories[id] = nil
        imageModels.remove(id)
        locations[id] = location
    }

    public func registering(decisions id: ModelID, location: ModelLocation = .unspecified, factory: @escaping DecisionFactory) -> ModelCatalog {
        var copy = self
        copy.register(decisions: id, location: location, factory: factory)
        return copy
    }

    public var ids: [ModelID] { Array(factories.keys) + Array(decisionFactories.keys) }

    func decisionModel(_ id: ModelID) async throws -> (any DecisionModel)? {
        try await decisionFactories[id]?()
    }

    func check(_ id: ModelID, policy: WorkflowExecutionPolicy, step: String) throws {
        guard factories[id] != nil || decisionFactories[id] != nil else { throw RelayError.unknownModel(id) }
        if policy.data == .localOnly, locations[id] != .local {
            throw RelayError.policyViolation(step: step, reason: "local-only data requires an explicitly local model")
        }
    }

    func isDecision(_ id: ModelID) -> Bool { decisionFactories[id] != nil }

    func supportsImages(_ id: ModelID) -> Bool { imageModels.contains(id) }

    func model(_ id: ModelID) async throws -> any LanguageModel {
        guard let factory = factories[id] else { throw RelayError.unknownModel(id) }
        return try await factory()
    }
}

/// Apple's on-device text recognition (Vision) as a `LanguageModel`: it reads
/// the text in the prompt's image exactly as written and ignores the
/// instruction. Nothing leaves the device. Only `readImage` steps use it.
public struct TextRecognitionModel: LanguageModel, Hashable {
    public init() {}

    public typealias UnavailableReason = Never

    public func respond<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt,
        generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        guard type == String.self, session.tools.isEmpty,
              let image = Self.lastImage(in: session.transcript) else {
            throw InvalidOutput(reason: "Apple Text Recognition only reads the text in images. Use it in Read Text in Image")
        }
        try Task.checkCancellation()
        let lines = try await Recognition.recognize(image, orientation: .up)
        guard !lines.isEmpty else { throw InvalidOutput(reason: "There's no readable text in the image") }
        let raw = GeneratedContent(lines.joined(separator: "\n"))
        return try .init(content: Content(raw), rawContent: raw, transcriptEntries: [])
    }

    public func streamResponse<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt,
        generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(stream: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(within: session, to: prompt, generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt, options: options)
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }

    private static func lastImage(in transcript: Transcript) -> CGImage? {
        for case .prompt(let prompt) in transcript.reversed() {
            for case .image(let image) in prompt.segments {
                if case .data(let data, _) = image.source { return ImageCoding.picture(from: data) }
            }
            return nil
        }
        return nil
    }

    /// Text recognition prepares its model the first time an app uses it,
    /// which can take a minute on a Mac. Call this in the background (say,
    /// when a workflow that uses it is opened) so the first run is quick.
    public static func prepare() async {
        let context = CGContext(data: nil, width: 160, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
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
                   abs(first.box.midY - piece.box.midY) < min(first.box.height, piece.box.height) / 2 {
                    rows[rows.count - 1].append(piece)
                } else {
                    rows.append([piece])
                }
            }
            return rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
        }
    }
}
