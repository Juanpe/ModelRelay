import Synchronization

/// The tools one agent step called, shared by its tools to enforce the limit.
final class ToolCallLog: Sendable {
    private struct State { var names: [String] = []; var active = true; var wrote = false }
    private let state = Mutex(State())
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var calls: [String] { state.withLock { $0.names } }
    var mayHaveWritten: Bool { state.withLock { $0.wrote } }
    func markWriteDispatched() { state.withLock { $0.wrote = true } }
    /// A backend retaining an old tool wrapper must not use it in a later step.
    func finish() { state.withLock { $0.active = false } }

    /// Records a call, or throws once the step has used all its calls.
    func record(_ name: String) throws {
        try state.withLock { state in
            guard state.active else { throw InvalidOutput(reason: "This step's tool access has ended") }
            guard state.names.count < limit else {
                throw InvalidOutput(reason: "The model called tools more than \(limit) times")
            }
            state.names.append(name)
        }
    }
}
