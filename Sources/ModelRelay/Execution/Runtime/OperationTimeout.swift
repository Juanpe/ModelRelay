import Foundation

struct OperationTimeout: Error, Sendable, CustomStringConvertible {
    let description: String
}

/// Runs `work`, failing with `InvalidOutput` if it takes longer than `limit`.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    message: String? = nil,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw OperationTimeout(description: message ?? "No answer within \(limit)")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
