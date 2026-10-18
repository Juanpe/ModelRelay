import Foundation
import Synchronization
import Testing
@testable import ModelRelay

actor HardeningStore: WorkflowExecutionCheckpointStore {
    private var entries: [UUID: Data] = [:]
    private var saved: WorkflowExecutionCheckpoint?
    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try entries[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        let data = try JSONEncoder().encode(checkpoint)
        entries[checkpoint.executionID] = data
        saved = try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: data)
    }

    func latest() throws -> WorkflowExecutionCheckpoint { try #require(saved) }
}

enum HostProblem: Error, Equatable, WorkflowFailureClassifiable {
    case authentication, rejected
    var workflowFailureCategory: WorkflowFailureCategory { self == .authentication ? .authenticationRequired : .requestRejected }
}

struct BrokenConnector: ToolServerConnector {
    func connect(to kit: ToolKit) async throws -> any ToolServerConnection { throw HostProblem.authentication }
}

struct BrokenTransport: RequestPerformer {
    func perform(_ request: PreparedRequest) async throws -> HTTPResponse { throw HostProblem.rejected }
}

final class CountedDecisions: DecisionModel {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func decide(_ questions: [Question], about input: String) async throws -> [Answer] {
        count.withLock { $0 += 1 }
        return questions.map { Answer(name: $0.name, result: .yesNo(true)) }
    }
}

actor ConcurrencyProbe {
    var active = 0
    var peak = 0
    var finished = 0
    func work() async throws -> Value {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(12))
        finished += 1
        return .text("done")
    }
}
