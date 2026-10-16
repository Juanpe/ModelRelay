import Foundation
import ModelRelay

/// A decision model behind an OpenAI-compatible `/decisions` endpoint, such as
/// TypeSafe's Jev (`typesafe-ai/jev`) through Vercel AI Gateway. It answers
/// typed questions with probabilities instead of writing text.
public struct DecisionsAPIModel: DecisionModel, Hashable, CustomStringConvertible {
    public static let aiGateway = URL(string: "https://ai-gateway.vercel.sh/v1")!

    public var baseURL: URL
    public var model: String
    /// Pass it from the Keychain; ModelRelay never stores it.
    public var apiKey: String
    /// On AI Gateway, only route to providers that keep no data. Vercel offers
    /// it on Pro and Enterprise plans and refuses it (HTTP 403) on Hobby.
    public var zeroDataRetention: Bool

    public init(model: String = "typesafe-ai/jev", apiKey: String, baseURL: URL = DecisionsAPIModel.aiGateway,
                zeroDataRetention: Bool = false) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.zeroDataRetention = zeroDataRetention
    }

    /// Hides the key, so logging a model never prints it.
    public var description: String { "\(model) at \(baseURL.host() ?? baseURL.absoluteString)" }

    public func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "questions": questions.map(Self.json),
        ]
        if zeroDataRetention, baseURL.host() == Self.aiGateway.host() {
            body["providerOptions"] = ["gateway": ["zeroDataRetention": true]]
        }
        let reply: [String: Any]
        do {
            reply = try await CloudHTTP.postJSON(baseURL.appending(path: "decisions"),
                headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        } catch var error as CloudModelError {
            if !apiKey.isEmpty { error.message = error.message.replacingOccurrences(of: apiKey, with: "•••") }
            throw error
        }
        let answers = reply["answers"] as? [[String: Any]] ?? []
        // Answers come back in question order.
        return try zip(questions, answers).map { question, answer in
            if answer["type"] as? String == "refusal" {
                throw CloudModelError(status: 200, message: "The model declined to answer \(question.name)")
            }
            let confidence = answer["confidence"] as? Double
            switch question.kind {
            case .yesNo:
                let probability = answer["probability"] as? Double ?? 0
                return Answer(name: question.name, result: .yesNo(probability >= 0.5), confidence: probability)
            case .choice:
                let choice = (answer["choice"] as? String) ?? (answer["choice"] as? Bool).map(String.init) ?? ""
                return Answer(name: question.name, result: .choice(choice), confidence: confidence)
            case .score(let levels):
                let score = answer["score"] as? Double ?? 0
                let index = min(max(Int(score.rounded()), 0), levels.count - 1)
                return Answer(name: question.name, result: .score(score, level: levels[index]), confidence: confidence)
            }
        }
    }

    private static func json(_ question: Question) -> [String: Any] {
        var json: [String: Any] = ["name": question.name, "instructions": question.instructions]
        switch question.kind {
        case .yesNo:
            json["type"] = "predicate"
        case .choice(let options):
            json["type"] = "choice"
            json["choices"] = options.map { option -> [String: Any] in
                var choice: [String: Any] = ["value": option.value]
                if let description = option.description { choice["description"] = description }
                return choice
            }
        case .score(let levels):
            json["type"] = "score"
            json["levels"] = levels.map { ["label": $0] }
        }
        return json
    }
}
