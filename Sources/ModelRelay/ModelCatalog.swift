import FoundationModels

/// Resolves a `ModelID` to a FoundationModels `LanguageModel`. Apps compose
/// catalogs: Apple's models are built in; MLX or cloud models are added by
/// registering a factory. ModelRelay itself never downloads or stores keys.
public struct ModelCatalog: Sendable {
    public typealias Factory = @Sendable () async throws -> any LanguageModel

    private var factories: [ModelID: Factory]

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

    public var ids: [ModelID] { Array(factories.keys) }

    func model(_ id: ModelID) async throws -> any LanguageModel {
        guard let factory = factories[id] else { throw RelayError.unknownModel(id) }
        return try await factory()
    }
}
