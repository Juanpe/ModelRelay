import Foundation

/// Reading MCP replies: JSON, or server-sent events that carry JSON.
enum MCPMessages {
    static func reply(to id: Int, in data: Data, contentType: String?) throws -> [String: Any]? {
        let messages: [Any]
        if contentType?.contains("text/event-stream") == true {
            messages = events(in: String(decoding: data, as: UTF8.self)).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            }
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw MCPError.invalidResponse("not JSON")
            }
            messages = (object as? [Any]) ?? [object]
        }

        return messages.compactMap { $0 as? [String: Any] }.first { message in
            (message["id"] as? Int) == id || (message["id"] as? String) == String(id)
        }
    }

    /// The data of each event: its `data:` lines joined.
    static func events(in stream: String) -> [String] {
        stream.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let data = block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { line in
                    let value = line.dropFirst("data:".count)
                    return value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)
                }

            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
    }
}
