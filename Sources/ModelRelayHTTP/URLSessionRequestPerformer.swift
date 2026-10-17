import Foundation
import ModelRelay

/// Sends request steps with URLSession. Ephemeral (no cookies, no cache), and
/// a redirect may only stay on the same host, so a header such as
/// `Authorization` never follows a call to somewhere else.
public struct URLSessionRequestPerformer: RequestPerformer {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func perform(_ request: PreparedRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue

        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }

        if let body = request.body {
            urlRequest.httpBody = body
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil, Self.looksLikeJSON(body) {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response) = try await session.data(for: urlRequest, delegate: SameHostRedirects(origin: request.url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        return HTTPResponse(status: status, body: data)
    }

    private static func looksLikeJSON(_ body: Data) -> Bool {
        guard let first = body.first(where: { !Character(UnicodeScalar($0)).isWhitespace }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }
}

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, url.host() == origin.host(), url.scheme == origin.scheme else { return nil }
        return request
    }
}
