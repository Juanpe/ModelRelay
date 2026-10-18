import Synchronization

/// What one step read, filled in as soon as it's known so a failure record
/// can include it.
final class StepTrace: Sendable {
    private let value = Mutex<String?>(nil)

    var input: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
