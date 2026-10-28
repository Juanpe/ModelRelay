import AnyLanguageModel

enum SchemaBuilder {
    /// A guided-generation schema for an object with `fields`.
    static func object(named name: String, fields: [Field]) throws -> GenerationSchema {
        var names: SchemaNames = .init()
        return try GenerationSchema(root: names.object(named: name, fields: fields), dependencies: [])
    }

    /// A schema whose only valid output is one of `labels`.
    static func label(from labels: [String]) throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Label", anyOf: labels), dependencies: [])
    }
}

/// Named nodes (objects and choices) become shared definitions keyed by name,
/// and a later node with the same name replaces an earlier one. Nested fields
/// often repeat names (`name`, `kind`), so each node gets its own.
private struct SchemaNames {
    private var used: Set<String> = []

    mutating func object(named name: String, fields: [Field]) -> DynamicGenerationSchema {
        let name: String = unique(name)
        return DynamicGenerationSchema(name: name, properties: fields.map { field in
            DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description,
                schema: schema(field.kind, named: field.name)
            )
        })
    }

    private mutating func schema(_ kind: Field.Kind, named name: String) -> DynamicGenerationSchema {
        switch kind {
        case .text: DynamicGenerationSchema(type: String.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .bool: DynamicGenerationSchema(type: Bool.self)
        case let .choice(options): DynamicGenerationSchema(name: unique(name), anyOf: options)
        case let .list(item): DynamicGenerationSchema(arrayOf: schema(item, named: name + "Item"))
        case let .object(fields): object(named: name, fields: fields)
        }
    }

    private mutating func unique(_ base: String) -> String {
        var name: String = base
        var suffix: Int = 2
        while !used.insert(name).inserted {
            name = "\(base)\(suffix)"
            suffix += 1
        }
        return name
    }
}
