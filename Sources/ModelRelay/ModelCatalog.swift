import FoundationModels

/// Resolves a `ModelID` to a FoundationModels `LanguageModel`. Apps compose
/// catalogs: Apple's models are built in; MLX or cloud models are added by
/// registering a factory. ModelRelay itself never downloads or stores keys.
public struct ModelCatalog: Sendable {
    public typealias Factory = @Sendable () async throws -> any LanguageModel

    public typealias DecisionFactory = @Sendable () async throws -> any DecisionModel

    private var factories: [ModelID: Factory]
    private var decisionFactories: [ModelID: DecisionFactory] = [:]

    public init() {
        factories = [
            .appleOnDevice: { SystemLanguageModel.default },
            .applePrivateCloud: { PrivateCloudComputeLanguageModel() },
        ]
    }

    public mutating func register(_ id: ModelID, factory: @escaping Factory) {
        factories[id] = factory
    }

    public func registering(_ id: ModelID, factory: @escaping Factory) -> ModelCatalog {
        var copy = self
        copy.register(id, factory: factory)
        return copy
    }

    /// Adds a model for decide steps (it answers questions; it doesn't write text).
    public mutating func register(decisions id: ModelID, factory: @escaping DecisionFactory) {
        decisionFactories[id] = factory
    }

    public func registering(decisions id: ModelID, factory: @escaping DecisionFactory) -> ModelCatalog {
        var copy = self
        copy.register(decisions: id, factory: factory)
        return copy
    }

    public var ids: [ModelID] { Array(factories.keys) + Array(decisionFactories.keys) }

    func decisionModel(_ id: ModelID) async throws -> (any DecisionModel)? {
        try await decisionFactories[id]?()
    }

    func model(_ id: ModelID) async throws -> any LanguageModel {
        guard let factory = factories[id] else { throw RelayError.unknownModel(id) }
        return try await factory()
    }
}
