import Foundation
import ModelRelay
import Synchronization

/// What a cloud model call failed with. Never contains the API key.
public struct CloudModelError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var message: String
    public var description: String { status == 0 ? message : "HTTP \(status): \(message)" }
}

enum CloudHTTP {
    /// Tests swap in a session whose protocol answers locally.
    static let session = Mutex(URLSession(configuration: .ephemeral))

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = session.withLock { $0 }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            // Say which server didn't answer, not just "the network connection was lost".
            throw CloudModelError(status: 0, message: "Couldn't reach \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = object["error"] as? [String: Any]
            throw CloudModelError(status: status, message: error?["message"] as? String ?? "The server refused the request")
        }
        return object
    }
}
