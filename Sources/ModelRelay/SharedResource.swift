import Foundation

/// Coalesces one run's loads without letting a timed-out waiter cancel another
/// parallel step's load. Only the last waiter leaving cancels the producer.
actor SharedResource<Resource: Sendable> {
    private var cached: Resource?
    private var generation: UUID?
    private var producer: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Resource, any Error>] = [:]
    var waiterCount: Int { waiters.count }

    func get(_ load: @escaping @Sendable () async throws -> Resource) async throws -> Resource {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let cached { return cached }
            return try await withCheckedThrowingContinuation { continuation in
                waiters[waiter] = continuation
                guard producer == nil else { return }
                let id = UUID()
                generation = id
                producer = Task {
                    do {
                        try Task.checkCancellation()
                        let value = try await load()
                        try Task.checkCancellation()
                        complete(.success(value), generation: id)
                    } catch { complete(.failure(error), generation: id) }
                }
            }
        } onCancel: { Task { await self.cancel(waiter) } }
    }

    private func complete(_ result: Result<Resource, any Error>, generation id: UUID) {
        guard generation == id else { return }
        if case .success(let value) = result { cached = value }
        let pending = waiters.values
        waiters.removeAll()
        producer = nil
        generation = nil
        for continuation in pending { continuation.resume(with: result) }
    }

    private func cancel(_ waiter: UUID) {
        waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if waiters.isEmpty { producer?.cancel(); producer = nil; generation = nil }
    }

    func finish() {
        producer?.cancel()
        producer = nil; generation = nil; cached = nil
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}
