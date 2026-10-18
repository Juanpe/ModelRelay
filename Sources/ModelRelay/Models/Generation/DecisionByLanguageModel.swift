import AnyLanguageModel
import Foundation

enum DecisionByLanguageModel {
    /// Asks a language model the questions with a guided schema: the same
    /// answers, without probabilities.
    static func decide(_ questions: [Question], about input: String, session: LanguageModelSession) async throws -> [Answer] {
        let properties = questions.map { question -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema = switch question.kind {
            case .yesNo: DynamicGenerationSchema(type: Bool.self)
            case let .choice(options): DynamicGenerationSchema(name: question.name, anyOf: options.map(\.value))
            case let .score(levels): DynamicGenerationSchema(name: question.name, anyOf: levels)
            }
            return DynamicGenerationSchema.Property(name: question.name, description: question.instructions, schema: schema)
        }

        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Answers", properties: properties), dependencies: [])
        let prompt = "Answer each question about the text below. Each field's description is its question.\n\nText:\n\(input)"
        let content = try await session.respond(to: prompt, schema: schema).content
        let value = Value(content)

        return try questions.map { question in
            guard let field = value[question.name] else {
                throw InvalidOutput(reason: "No answer for \(question.name)")
            }

            switch question.kind {
            case .yesNo:
                guard case let .bool(yes) = field else { throw InvalidOutput(reason: "\(question.name) isn't yes or no") }
                return Answer(name: question.name, result: .yesNo(yes))

            case let .choice(options):
                let text = field.textValue.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                guard let option = options.first(where: { $0.value.caseInsensitiveCompare(text) == .orderedSame }) else {
                    throw InvalidOutput(reason: "\(question.name) isn't one of the options")
                }
                return Answer(name: question.name, result: .choice(option.value))

            case let .score(levels):
                let text = field.textValue.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                guard let index = levels.firstIndex(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else {
                    throw InvalidOutput(reason: "\(question.name) isn't one of the levels")
                }
                return Answer(name: question.name, result: .score(Double(index), level: levels[index]))
                
            }
        }
    }
}
