/// One field an extract step must produce. Fields are defined at run time (by
/// the person building the workflow), so they become a dynamic schema that
/// guides generation instead of a compile-time `@Generable` type.
public struct Field: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case text, number, bool
        case choice([String])
        indirect case list(Kind)
        /// Named fields of their own, such as each line of an order in a
        /// `.list(.object([...]))`. The result is a dictionary.
        case object([Field])
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
