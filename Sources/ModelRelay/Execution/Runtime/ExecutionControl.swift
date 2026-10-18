import Foundation
import Synchronization

/// Serializes progress emission and shares budgets across parallel branches.
final class ExecutionControl: Sendable {
    let executionID: UUID
    let workflowID: UUID
    let limits: WorkflowExecutionLimits
    private let invocationID = UUID()
    private let began = ContinuousClock.now
    private let priorDuration: Duration
    private let usageState: Mutex<WorkflowExecutionUsage>
    private struct Progress: Sendable {
        var sequence = 0
        var updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation?
    }

    private let progress: Mutex<Progress>
    private let slots: ExecutionSlots

    init(
        workflowID: UUID,
        limits: WorkflowExecutionLimits,
        executionID: UUID = UUID(),
        usage: WorkflowExecutionUsage = .init(),
        duration: Duration = .zero,
        updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation? = nil
    ) {
        self.workflowID = workflowID; self.executionID = executionID; self.limits = limits
        priorDuration = duration; usageState = Mutex(usage); progress = Mutex(Progress(updates: updates))
        slots = ExecutionSlots(limit: limits.maxConcurrentSteps)
    }

    var usage: WorkflowExecutionUsage { usageState.withLock { $0 } }
    func accountReconciledTool() { usageState.withLock { if $0.toolCalls < Int.max { $0.toolCalls += 1 } } }
    func finish() { progress.withLock { $0.updates = nil } }
    var duration: Duration { priorDuration + (ContinuousClock.now - began) }

    func emit(_ record: StepRecord) {
        _ = progress.withLock { $0.updates?.yield(.step(record)) }
    }

    func emit(
        _ kind: WorkflowExecutionEvent.Kind,
        step: String? = nil,
        model: ModelID? = nil,
        tool: String? = nil,
        category: WorkflowFailureCategory? = nil,
        generation: Int? = nil,
        limit: WorkflowExecutionLimit? = nil
    ) {
        progress.withLock { progress in
            guard let updates = progress.updates else { return }
            progress.sequence += 1
            updates.yield(.event(.init(
                executionID: executionID,
                workflowID: workflowID,
                invocationID: invocationID,
                sequence: progress.sequence,
                kind: kind,
                step: step,
                model: model,
                tool: tool,
                failureCategory: category,
                checkpointGeneration: generation,
                limit: limit
            )))
        }
    }

    func check() throws {
        try Task.checkCancellation()
        if let max = limits.maxDuration, duration >= max { try exceeded(.duration) }
    }

    private func exceeded(_ limit: WorkflowExecutionLimit) throws -> Never {
        emit(.limitReached, category: .limitExceeded, limit: limit)
        throw RelayError.limitExceeded(limit)
    }

    func beginModel(_ model: ModelID, step: String) throws {
        try check()
        let allowed = usageState.withLock { usage in
            if usage.modelCalls == Int.max { return false }
            if let max = limits.maxModelCalls, usage.modelCalls >= max { return false }
            usage.modelCalls += 1; return true
        }
        guard allowed else { try exceeded(.modelCalls) }
        emit(.modelStarted, step: step, model: model)
    }

    func beginTool(_ tool: String, step: String) throws {
        try check()
        let allowed = usageState.withLock { usage in
            if usage.toolCalls == Int.max { return false }
            if let max = limits.maxToolCalls, usage.toolCalls >= max { return false }
            usage.toolCalls += 1; return true
        }
        guard allowed else { try exceeded(.toolCalls) }
        emit(.toolStarted, step: step, tool: tool)
    }

    func acquire() async throws { try check(); try await slots.acquire() }
    func release() async { await slots.release() }

    func withDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try check()
        guard let max = limits.maxDuration else { return try await operation() }
        let remaining = max - duration
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: remaining)
                try self.exceeded(.duration)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
