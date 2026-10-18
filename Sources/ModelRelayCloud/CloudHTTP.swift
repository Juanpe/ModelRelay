import Foundation
import ModelRelay
import ModelRelayHTTP

/// What a cloud model call failed with. Never contains the API key.
public struct CloudModelError: Error, CustomStringConvertible, Sendable, WorkflowFailureClassifiable {
    public var status: Int
    public var message: String
    public var description: String { status == 0 ? message : "HTTP \(status): \(message)" }
    public var workflowFailureCategory: WorkflowFailureCategory {
        switch status {
        case 0: .transport
        case 401: .authenticationRequired
        case 403: .permissionDenied
        case 429: .modelUnavailable
        default: .requestRejected
        }
    }
}

struct CloudHTTP: Sendable, Hashable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request: URLRequest = .init(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            // Say which server didn't answer, not just "the network connection was lost".
            throw CloudModelError(status: 0, message: "Couldn't reach \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
        }

        guard let reply = HTTPResponse(data: data, response: response) else {
            throw CloudModelError(status: 0, message: "The server didn't return an HTTP response")
        }
        try reply.validateSuccess(or: CloudModelError(
            status: reply.status,
            message: HTTPResponse.errorMessage(in: reply.jsonObject ?? [:], keys: ["error"]) ?? "The server refused the request"
        ))

        guard let object = reply.jsonObject else {
            throw CloudModelError(status: reply.status, message: "The server returned an invalid JSON object")
        }

        return object
    }
}
