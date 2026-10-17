import Foundation

/// Encodes scripted replies as actual provider SSE wire events. Only used by
/// local URLProtocol stubs; production uses native provider streaming.
enum ProviderStreamFixture {
    static func data(from body: Data) -> Data {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        var events = ""
        func event(_ name: String? = nil, _ value: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: value)
            if let name { events += "event: \(name)\n" }
            events += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        if let choices = json["choices"] as? [[String: Any]], var message = choices.first?["message"] as? [String: Any] {
            if var calls = message["tool_calls"] as? [[String: Any]] {
                for index in calls.indices {
                    calls[index]["index"] = index
                }
                message["tool_calls"] = calls
            }
            event(nil, ["id": "chat-test", "object": "chat.completion.chunk", "created": 0, "model": "scripted",
                        "choices": [["index": 0, "delta": message]]])
            events += "data: [DONE]\n\n"
        } else if let blocks = json["content"] as? [[String: Any]] {
            event("message_start", ["type": "message_start",
                                    "message": ["id": "m1", "type": "message", "role": "assistant", "model": "scripted", "content": []]])
            for (index, block) in blocks.enumerated() {
                var start = block
                let type = block["type"] as? String ?? ""
                if type == "text" { start["text"] = "" }
                if type == "tool_use" { start["input"] = [String: Any]() }
                event("content_block_start", ["type": "content_block_start", "index": index, "content_block": start])
                if type == "text" {
                    event("content_block_delta", ["type": "content_block_delta", "index": index,
                                                  "delta": ["type": "text_delta", "text": block["text"] as? String ?? ""]])
                } else if type == "tool_use" {
                    let data = try! JSONSerialization.data(withJSONObject: block["input"] ?? [:])
                    event("content_block_delta", ["type": "content_block_delta", "index": index,
                                                  "delta": ["type": "input_json_delta", "partial_json": String(decoding: data, as: UTF8.self)]])
                }
                event("content_block_stop", ["type": "content_block_stop", "index": index])
            }
            event("message_delta", ["type": "message_delta", "delta": ["stop_reason": json["stop_reason"] ?? "end_turn"]])
            event("message_stop", ["type": "message_stop"])
        } else { return body }
        return Data(events.utf8)
    }
}
