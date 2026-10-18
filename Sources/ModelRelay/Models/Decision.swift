import Foundation

/// One typed question a decide step asks about its text.
public struct Question: Codable, Sendable, Hashable {
    public struct Option: Codable, Sendable, Hashable {
        public var value: String
        public var description: String?

        public init(_ value: String, description: String? = nil) {
            self.value = value
            self.description = description
        }
    }

    public enum Kind: Codable, Sendable, Hashable {
        /// Yes or no; decision models also give the probability of yes.
        case yesNo
        /// Exactly one of the options.
        case choice([Option])
        /// One of 2 to 10 ordered levels, lowest first ("low", "medium", "high").
        case score([String])
    }

    public var name: String
    public var instructions: String
    public var kind: Kind

    public init(_ name: String, _ instructions: String, _ kind: Kind) {
        self.name = name
        self.instructions = instructions
        self.kind = kind
    }
}

/// A decision model's answer. `confidence` is nil when the model doesn't give one.
public struct Answer: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        case yesNo(Bool)
        case choice(String)
        /// The probability-weighted level index (0 is the first level) and the
        /// level closest to it.
        case score(Double, level: String)
    }

    public var name: String
    public var result: Result
    public var confidence: Double?

    public init(name: String, result: Result, confidence: Double? = nil) {
        self.name = name
        self.result = result
        self.confidence = confidence
    }
}

/// A model that answers typed questions directly, with probabilities, rather
/// than writing text (for example TypeSafe's Jev through Vercel AI Gateway).
/// `ModelRelayCloud` has one for the OpenAI-compatible `/decisions` API.
public protocol DecisionModel: Sendable {
    func decide(_ questions: [Question], about input: String) async throws -> [Answer]
}

extension Question {
    /// What's wrong with this question for a decision model, or nil. Checked
    /// before anything is sent, so the reason is clear instead of an HTTP 400.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A question has no name" }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Question “\(name)” has no question text" }
        switch kind {
        case .yesNo: return nil
        case let .choice(options):
            if options.isEmpty || options.count > 255 { return "Question “\(name)” needs between 1 and 255 options" }
            if Set(options.map(\.value)).count != options.count { return "Question “\(name)” repeats an option" }
            return nil
        case let .score(levels):
            if levels.count < 2 || levels.count > 10 { return "Question “\(name)” needs between 2 and 10 levels" }
            return nil
        }
    }

    static func problem(in questions: [Question]) -> String? {
        if questions.isEmpty { return "There are no questions" }
        if Set(questions.map(\.name)).count != questions.count { return "Two questions share a name" }
        return questions.lazy.compactMap(\.problem).first
    }
}

extension Answer {
    /// The step's result: one field per question, plus `confidence` per
    /// question when the model gave it, and `scores` for score questions.
    static func value(_ answers: [Answer]) -> Value {
        var fields: [String: Value] = [:]
        var confidence: [String: Value] = [:]
        var scores: [String: Value] = [:]
        for answer in answers {
            switch answer.result {
            case let .yesNo(yes): fields[answer.name] = .bool(yes)
            case let .choice(value): fields[answer.name] = .text(value)
            case let .score(score, level):
                fields[answer.name] = .text(level)
                scores[answer.name] = .number((score * 100).rounded() / 100)
            }
            if let value = answer.confidence { confidence[answer.name] = .number((value * 100).rounded() / 100) }
        }
        if !confidence.isEmpty { fields["confidence"] = .dictionary(confidence) }
        if !scores.isEmpty { fields["scores"] = .dictionary(scores) }
        return .dictionary(fields)
    }
}
