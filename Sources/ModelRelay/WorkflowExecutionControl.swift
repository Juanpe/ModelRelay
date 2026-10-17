import Foundation
import Synchronization

/// Limits on executor-mediated work, not a sandbox for host code. Model calls
/// count session/decision attempts (including fallback), not provider-internal
/// HTTP continuation rounds. Tool calls include direct HTTP request steps.
public struct WorkflowExecutionLimits: Codable, Sendable, Hashable {
    public var maxDuration: Duration?
    public var maxModelCalls: Int?
    public var maxToolCalls: Int?
    /// Concurrent leaf steps; blocks do not hold slots, preventing nested deadlock.
    public var maxConcurrentSteps: Int?
    public init(
        maxDuration: Duration? = nil,
        maxModelCalls: Int? = nil,
        maxToolCalls: Int? = nil,
        maxConcurrentSteps: Int? = nil
    ) {
        self.maxDuration = maxDuration; self.maxModelCalls = maxModelCalls
        self.maxToolCalls = maxToolCalls; self.maxConcurrentSteps = maxConcurrentSteps
    }

    public static let unlimited = Self()

    func validate() throws {
        guard maxDuration.map({ $0 >= .zero }) ?? true,
              maxModelCalls.map({ $0 >= 0 }) ?? true, maxToolCalls.map({ $0 >= 0 }) ?? true,
              maxConcurrentSteps.map({ $0 > 0 }) ?? true
        else {
            throw RelayError.invalidLimits
        }
    }

    func narrowed(by other: Self) -> Self {
        func smaller<T: Comparable>(_ a: T?, _ b: T?) -> T? {
            switch (a, b) { case let (.some(a), .some(b)): min(a, b); default: a ?? b }
        }
        return Self(
            maxDuration: smaller(maxDuration, other.maxDuration),
            maxModelCalls: smaller(maxModelCalls, other.maxModelCalls),
            maxToolCalls: smaller(maxToolCalls, other.maxToolCalls),
            maxConcurrentSteps: smaller(maxConcurrentSteps, other.maxConcurrentSteps)
        )
    }
}

public enum WorkflowExecutionLimit: String, Codable, Sendable, Hashable {
    case duration, modelCalls, toolCalls
}

public struct WorkflowExecutionUsage: Codable, Sendable, Hashable {
    public internal(set) var modelCalls: Int = 0
    public internal(set) var toolCalls: Int = 0
    public init() {}
}

/// Metadata only: never contains prompts, values, arguments, credentials or
/// raw error descriptions. Names/IDs are host-defined, not automatically PII-free.
public struct WorkflowExecutionEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case executionStarted, executionResumed, executionCompleted, executionFailed, executionCancelled
        case stepStarted, stepCompleted, stepSkipped, stepFailed
        case modelStarted, modelCompleted, modelFailed, fallbackSelected
        case toolStarted, toolCompleted, toolFailed
        case approvalRequired, approvalRejected, checkpointSaved, limitReached
    }

    public let executionID: UUID
    public let workflowID: UUID
    /// Each resume has a fresh invocation ID; sequence is ordered within it.
    public let invocationID: UUID
    public let sequence: Int
    public let kind: Kind
    public let step: String?
    public let model: ModelID?
    public let tool: String?
    public let failureCategory: WorkflowFailureCategory?
    public let checkpointGeneration: Int?
    public let limit: WorkflowExecutionLimit?
}

/// Serializes metadata emission and shares budgets across parallel branches.
final class ExecutionControl: Sendable {
    let executionID: UUID
    let workflowID: UUID
    let limits: WorkflowExecutionLimits
    private let invocationID = UUID()
    private let began = ContinuousClock.now
    private let priorDuration: Duration
    private let usageState: Mutex<WorkflowExecutionUsage>
    private struct Events: Sendable {
        var sequence = 0
        var observer: (@Sendable (WorkflowExecutionEvent) -> Void)?
    }

    private let events: Mutex<Events>
    private let slots: ExecutionSlots

    init(
        workflowID: UUID,
        executionID: UUID = UUID(),
        limits: WorkflowExecutionLimits,
        usage: WorkflowExecutionUsage = .init(),
        duration: Duration = .zero,
        observer: (@Sendable (WorkflowExecutionEvent) -> Void)?
    ) {
        self.workflowID = workflowID; self.executionID = executionID; self.limits = limits
        priorDuration = duration; usageState = Mutex(usage); events = Mutex(Events(observer: observer))
        slots = ExecutionSlots(limit: limits.maxConcurrentSteps)
    }

    var usage: WorkflowExecutionUsage { usageState.withLock { $0 } }
    func accountReconciledTool() { usageState.withLock { if $0.toolCalls < Int.max { $0.toolCalls += 1 } } }
    func finish() { events.withLock { $0.observer = nil } }
    var duration: Duration { priorDuration + (ContinuousClock.now - began) }

    func emit(
        _ kind: WorkflowExecutionEvent.Kind,
        step: String? = nil,
        model: ModelID? = nil,
        tool: String? = nil,
        category: WorkflowFailureCategory? = nil,
        generation: Int? = nil,
        limit: WorkflowExecutionLimit? = nil
    ) {
        events.withLock { events in
            guard let observer = events.observer else { return }
            events.sequence += 1
            observer(.init(
                executionID: executionID,
                workflowID: workflowID,
                invocationID: invocationID,
                sequence: events.sequence,
                kind: kind,
                step: step,
                model: model,
                tool: tool,
                failureCategory: category,
                checkpointGeneration: generation,
                limit: limit
            ))
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

/// Cancellation-aware FIFO slots shared by all nested parallel branches.
private actor ExecutionSlots {
    let limit: Int?
    var active = 0
    var queue: [UUID] = []
    var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    init(limit: Int?) { self.limit = limit }
    func acquire() async throws {
        guard let limit else { try Task.checkCancellation(); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active < limit { active += 1; continuation.resume() }
                else { queue.append(id); waiting[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
        queue.removeAll { $0 == id }
    }

    func release() {
        guard limit != nil else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let continuation = waiting.removeValue(forKey: id) { continuation.resume(); return }
        }
        active -= 1
    }
}
