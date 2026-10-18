import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import ModelRelay

enum StoreFailure: Error { case unavailable }

/// Test-only, JSON round-tripping CAS store. Production storage is host-owned.
actor MemoryCheckpoints: WorkflowExecutionCheckpointStore {
    private var data: [UUID: Data] = [:]
    private var history: [WorkflowExecutionCheckpoint] = []
    var failBefore: Int?
    var failAfter: Int?

    init(failBefore: Int? = nil, failAfter: Int? = nil) {
        self.failBefore = failBefore
        self.failAfter = failAfter
    }

    func save(_ checkpoint: WorkflowExecutionCheckpoint, replacing generation: Int?) throws {
        let current = try data[checkpoint.executionID].map { try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: $0) }
        guard current?.generation == generation else { throw RecoveryError.checkpointConflict }
        if checkpoint.generation == failBefore { failBefore = nil; throw StoreFailure.unavailable }
        let encoded = try JSONEncoder().encode(checkpoint)
        data[checkpoint.executionID] = encoded
        history.append(try JSONDecoder().decode(WorkflowExecutionCheckpoint.self, from: encoded))
        if checkpoint.generation == failAfter { failAfter = nil; throw StoreFailure.unavailable }
    }

    func latest() throws -> WorkflowExecutionCheckpoint { try #require(history.last) }
    var saves: [WorkflowExecutionCheckpoint] { history }
}

func paused(_ outcome: WorkflowExecutionOutcome) throws -> WorkflowExecutionCheckpoint {
    guard case let .awaitingApproval(checkpoint) = outcome else { throw RecoveryError.invalidCheckpoint("expected approval") }
    return checkpoint
}

func completed(_ outcome: WorkflowExecutionOutcome) throws -> WorkflowExecutionReport {
    guard case let .completed(report) = outcome else { throw RecoveryError.invalidCheckpoint("expected completion") }
    return report
}
