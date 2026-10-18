import Foundation

/// Cancellation-aware FIFO slots shared by all nested parallel branches.
actor ExecutionSlots {
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
