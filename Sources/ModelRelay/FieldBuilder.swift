/// Builds an extraction schema from fields and reusable field arrays.
@resultBuilder
public enum FieldBuilder {
    /// Adds one field.
    public static func buildExpression(_ field: Field) -> [Field] { [field] }
    /// Adds existing fields.
    public static func buildExpression(_ fields: [Field]) -> [Field] { fields }
    /// Joins fields in declaration order.
    public static func buildBlock(_ components: [Field]...) -> [Field] { components.flatMap { $0 } }
    /// Supports an optional construction-time field group.
    public static func buildOptional(_ component: [Field]?) -> [Field] { component ?? [] }
    /// Supports the first construction-time conditional branch.
    public static func buildEither(first component: [Field]) -> [Field] { component }
    /// Supports the second construction-time conditional branch.
    public static func buildEither(second component: [Field]) -> [Field] { component }
    /// Supports a construction-time loop of fields.
    public static func buildArray(_ components: [[Field]]) -> [Field] { components.flatMap { $0 } }
    /// Supports availability checks while building the schema.
    public static func buildLimitedAvailability(_ component: [Field]) -> [Field] { component }
}
