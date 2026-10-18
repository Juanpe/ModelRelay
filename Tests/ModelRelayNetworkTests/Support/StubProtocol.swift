import Foundation

/// Answers every URLSession request locally with a scripted reply and keeps
/// what was sent. Nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
    /// Replies used in order before falling back to `reply`.
    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var sent: [Sent] = []
    /// Response headers for the queued replies, in the same order.
    nonisolated(unsafe) static var headerQueue: [[String: String]] = []
    nonisolated(unsafe) static var responseIsHTTP: Bool = true

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.sent.append(Sent(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        ))
        let next = Self.queue.isEmpty ? Self.reply : Self.queue.removeFirst()
        var headers = Self.headerQueue.isEmpty ? [:] : Self.headerQueue.removeFirst()
        let streaming = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["stream"] as? Bool == true
        if streaming { headers["Content-Type"] = "text/event-stream" }
        else if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        let response: URLResponse
        if Self.responseIsHTTP {
            guard let http = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            response = http
        } else {
            response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: -1, textEncodingName: nil)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: streaming ? ProviderStreamFixture.data(from: Self.providerEnvelope(next.body)) : Self.providerEnvelope(next.body))
        client?.urlProtocolDidFinishLoading(self)
    }

    // Fill the standard wire envelope around concise provider fixtures.
    private static func providerEnvelope(_ body: String) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return Data(body.utf8) }
        if var choices = json["choices"] as? [[String: Any]] {
            json["id"] = "chat-test"; json["object"] = "chat.completion"; json["created"] = 0; json["model"] = "scripted"
            for index in choices.indices {
                choices[index]["index"] = index
                var message = choices[index]["message"] as? [String: Any] ?? [:]
                message["role"] = "assistant"
                choices[index]["message"] = message
                choices[index]["finish_reason"] = message["tool_calls"] == nil ? "stop" : "tool_calls"
            }
            json["choices"] = choices
        } else if json["content"] is [[String: Any]] {
            json["id"] = "message-test"; json["type"] = "message"; json["role"] = "assistant"; json["model"] = "scripted"
            if json["stop_reason"] == nil { json["stop_reason"] = "end_turn" }
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data(body.utf8)
    }

    override func stopLoading() {}
}
