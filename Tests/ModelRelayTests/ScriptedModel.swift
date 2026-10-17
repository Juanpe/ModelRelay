import AnyLanguageModel
import Foundation
import Synchronization
@testable import ModelRelay

func expectedOperationFailure(
    step: String,
    reason: String,
    category: WorkflowFailureCategory,
    uncertain: Bool = false
) -> RelayError {
    struct Expected: Error {}
    return .operationFailed(step: step, failure: .init(
        info: .init(category: category, message: reason, outcomeUncertain: uncertain), underlyingError: Expected()
    ))
}

/// Native AnyLanguageModel test backend. Calls go through the real session;
/// tool behavior is also verified against real providers using stubbed HTTP.
final class ScriptedModel: LanguageModel {
    typealias UnavailableReason = Never
    struct Failure: Error {}

    let name: String
    let seesImages: Bool
    private let replies: Mutex<[String?]>
    private let calls = Mutex(0)
    private let seen = Mutex<[String]>([])
    private let transcripts = Mutex<[Transcript]>([])
    private let sessions = Mutex<[ObjectIdentifier]>([])
    private let toolNames = Mutex<[[String]]>([])
    private let pictures = Mutex<[Transcript.ImageSegment]>([])

    init(_ name: String, replies: [String?], seesImages: Bool = true) {
        self.name = name
        self.seesImages = seesImages
        self.replies = Mutex(replies)
    }

    var histories: [Transcript] { transcripts.withLock { $0 } }
    var sessionIDs: [ObjectIdentifier] { sessions.withLock { $0 } }
    var visibleTools: [[String]] { toolNames.withLock { $0 } }
    var callCount: Int { calls.withLock { $0 } }
    var prompts: [String] { seen.withLock { $0 } }
    var images: [Transcript.ImageSegment] { pictures.withLock { $0 } }

    func respond<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        var entries: [Transcript.Entry] = []
        while true {
            try Task.checkCancellation()
            let request = session.resolvedRequestContext()
            toolNames.withLock { $0.append(request.tools.map(\.name)) }
            let transcript = Transcript(entries: Array(request.transcript) + entries)
            transcripts.withLock { $0.append(transcript) }
            sessions.withLock { $0.append(ObjectIdentifier(session)) }
            record(transcript)
            guard let reply = next() else { throw Failure() }
            if reply == "<hang>" { try await Task.sleep(for: .seconds(60)) }
            if reply.hasPrefix("<tool:"), let close = reply.firstIndex(of: ">") {
                let name = String(reply[reply.index(reply.startIndex, offsetBy: 6) ..< close])
                let arguments = try GeneratedContent(json: String(reply[reply.index(after: close)...]))
                let call = Transcript.ToolCall(id: UUID().uuidString, toolName: name, arguments: arguments)
                entries.append(.toolCalls(.init([call])))
                guard let tool = request.tools.first(where: { $0.name == name }) else { throw Failure() }
                do {
                    let output = try await execute(tool, arguments: arguments)
                    entries.append(.toolOutput(.init(id: call.id, toolName: name, segments: [.text(.init(content: output))])))
                } catch {
                    throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
                }
                continue
            }
            let raw: GeneratedContent = if type == String.self {
                GeneratedContent(reply)
            } else {
                // Existing scripted labels include deliberately invalid plain
                // strings to exercise executor validation/fallback.
                (try? GeneratedContent(json: reply)) ?? GeneratedContent(reply)
            }
            return try .init(content: Content(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
        }
    }

    func streamResponse<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(stream: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(
                        within: session,
                        to: prompt,
                        generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt,
                        options: options
                    )
                    continuation.yield(.init(
                        content: response.content.asPartiallyGenerated(),
                        rawContent: response.rawContent,
                        transcriptEntries: response.transcriptEntries
                    ))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }

    private func execute<T: Tool>(_ tool: T, arguments: GeneratedContent) async throws -> String {
        let output = try await tool.call(arguments: T.Arguments(arguments))
        return output.promptRepresentation.description
    }

    private func record(_ transcript: Transcript) {
        func text(_ segments: [Transcript.Segment]) -> String {
            segments.compactMap { segment in
                if case let .text(text) = segment { text.content } else { nil }
            }.joined()
        }
        let text = transcript.compactMap { entry -> String? in
            switch entry {
            case let .prompt(prompt): text(prompt.segments)
            case let .toolOutput(output): "[\(output.toolName)] " + text(output.segments)
            default: nil
            }
        }.joined(separator: "\n")
        seen.withLock { $0.append(text) }
        for case let .prompt(prompt) in transcript {
            for case let .image(image) in prompt.segments {
                pictures.withLock { $0.append(image) }
            }
        }
    }

    private func next() -> String? {
        calls.withLock { $0 += 1 }
        return replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

extension ModelCatalog {
    static func scripted(_ models: [ModelID: ScriptedModel]) -> ModelCatalog {
        var catalog = ModelCatalog()
        for (id, model) in models {
            catalog.register(id, supportsImages: model.seesImages) { model }
        }
        return catalog
    }
}
