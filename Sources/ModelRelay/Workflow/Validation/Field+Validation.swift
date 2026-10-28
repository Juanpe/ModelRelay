import Foundation

extension [Field] {
    /// Why these fields can't become a guided-generation schema, nested objects included.
    var schemaProblems: [String] {
        var problems: [String] = []
        if Set(map(\.name)).count != count || contains(where: { $0.name.isEmpty }) {
            problems.append("fields need unique nonempty names")
        }
        for field in self {
            problems += field.kind.schemaProblems
        }
        return problems
    }
}

extension Field.Kind {
    var schemaProblems: [String] {
        switch self {
        case let .choice(options):
            let blank: Bool = options.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return options.isEmpty || blank || Set(options).count != options.count ? ["choices must be nonempty and unique"] : []
        case let .list(item):
            return item.schemaProblems
        case let .object(fields):
            return (fields.isEmpty ? ["objects need at least one field"] : []) + fields.schemaProblems
        case .text, .number, .bool:
            return []
        }
    }
}
