import Foundation
import Synchronization
import Testing
@testable import ModelRelay

/// Answers every request with a fixed response and remembers what it was sent.
final class FakeServer: RequestPerformer {
    private let response: HTTPResponse
    private let sent = Mutex<[PreparedRequest]>([])

    init(status: Int = 200, json: String) {
        response = HTTPResponse(status: status, body: Data(json.utf8))
    }

    var requests: [PreparedRequest] { sent.withLock { $0 } }

    func perform(_ request: PreparedRequest) async throws -> HTTPResponse {
        sent.withLock { $0.append(request) }
        return response
    }
}

struct FakeSecrets: SecretProvider {
    var values: [String: String]
    func secret(named name: String) async throws -> String? { values[name] }
}
