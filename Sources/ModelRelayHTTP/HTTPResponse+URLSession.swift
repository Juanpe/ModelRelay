import Foundation
import ModelRelay

extension HTTPResponse {
    package init?(data: Data, response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]

        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }

        self.init(status: http.statusCode, body: data, headers: headers)
    }
}
