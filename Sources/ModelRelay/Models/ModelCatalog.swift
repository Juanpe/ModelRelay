import AnyLanguageModel
import Foundation

/// Trust metadata supplied by the host, not inferred from a model's name or URL.
/// A local declaration is an assertion about the entire provider implementation.
public enum ModelLocation: String, Codable, Sendable, Hashable {
    case local, remote, unspecified
}

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
        if #available(macOS 27, iOS 27, visionOS 27, *) {
            if SystemLanguageModel.default.supportsImageInput { imageModels.insert(.appleOnDevice) }
            if PrivateCloudComputeLanguageModel.default.supportsImageInput { imageModels.insert(.applePrivateCloud) }
        }
        factories = [
            .appleOnDevice: {
                guard #available(macOS 26, iOS 26, visionOS 26, *) else {
                    throw PlatformModelUnavailable(name: "Apple on-device", version: 26)
                }
                return SystemLanguageModel.default
            },
            .applePrivateCloud: {
                guard #available(macOS 27, iOS 27, visionOS 27, *) else {
                    throw PlatformModelUnavailable(name: "Apple Private Cloud Compute", version: 27)
                }
                return PrivateCloudComputeLanguageModel()
            },
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

private struct PlatformModelUnavailable: LocalizedError, WorkflowFailureClassifiable {
    let name: String
    let version: Int
    var errorDescription: String? { "\(name) requires iOS \(version), macOS \(version) or visionOS \(version)." }
    var workflowFailureCategory: WorkflowFailureCategory { .modelUnavailable }
}
