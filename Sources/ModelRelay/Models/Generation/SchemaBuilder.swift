import AnyLanguageModel

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
