import Foundation

public struct HTTPResponse: Sendable {
    package static let unauthorizedStatus: Int = 401
    private static let successfulStatuses: Range<Int> = 200 ..< 300

    public var status: Int
    public var body: Data
    private let headers: [String: String]

    public init(status: Int, body: Data) {
        self.init(status: status, body: body, headers: [:])
    }

    package init(status: Int, body: Data, headers: [String: String]) {
        self.status = status
        self.body = body
        var normalized: [String: String] = [:]

        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }

        self.headers = normalized
    }

    package var jsonObject: [String: Any]? { Self.jsonObject(from: body) }

    package func header(named name: String) -> String? {
        headers[name.lowercased()]
    }

    package func validateSuccess<Failure: Error>(or failure: @autoclosure () -> Failure) throws {
        guard Self.successfulStatuses.contains(status) else { throw failure() }
    }

    package static func jsonObject(from body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    package static func errorMessage(
        in object: [String: Any],
        keys: [String] = ["description", "message", "error_description", "detail", "error"]
    ) -> String? {
        for key in keys {
            if let text = object[key] as? String { return text }
            if let nested = object[key] as? [String: Any], let text = nested["message"] as? String { return text }
        }

        return nil
    }
}
