import AnyLanguageModel

/// One field an extract step must produce. Fields are defined at run time (by
/// the person building the workflow), so they become a dynamic schema that
/// guides generation instead of a compile-time `@Generable` type.
public struct Field: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case text, number, bool
        case choice([String])
        indirect case list(Kind)
    }

    public var name: String
    public var kind: Kind
    public var description: String?

    public init(_ name: String, _ kind: Kind, description: String? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
    }
}

extension Field.Kind {
    func schema(named name: String) -> DynamicGenerationSchema {
        switch self {
        case .text: DynamicGenerationSchema(type: String.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .bool: DynamicGenerationSchema(type: Bool.self)
        case let .choice(options): DynamicGenerationSchema(name: name, anyOf: options)
        case let .list(item): DynamicGenerationSchema(arrayOf: item.schema(named: name + "Item"))
        }
    }
}

enum SchemaBuilder {
    /// A guided-generation schema for an object with `fields`.
    static func object(named name: String, fields: [Field]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: name, properties: fields.map { field in
            DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description,
                schema: field.kind.schema(named: field.name)
            )
        })
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// A schema whose only valid output is one of `labels`.
    static func label(from labels: [String]) throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Label", anyOf: labels), dependencies: [])
    }
}
