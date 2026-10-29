import Foundation

/// One decoded line of `claude --output-format stream-json`.
enum ClaudeEvent: Equatable {
    case textDelta(String)
    /// Tool name with the `mcp__bluey__` prefix removed.
    case toolUse(String)
    case result(text: String, isError: Bool)
    case other
}

/// Pure encoding/decoding for the `claude -p` stream-json protocol; no process handling.
enum ClaudeStream {
    private static let toolPrefix = "mcp__bluey__"

    static func arguments(model: String, systemPrompt: String, mcpConfig: String) -> [String] {
        ["-p", "--model", model, "--tools", "", "--no-session-persistence", "--setting-sources", "",
         "--strict-mcp-config", "--mcp-config", mcpConfig, "--allowedTools", "mcp__bluey", "--disable-slash-commands",
         "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--include-partial-messages", "--system-prompt", systemPrompt]
    }

    static func userLine(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func interruptLine(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    static func parse(_ line: String) -> ClaudeEvent {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return .other }
        switch json["type"] as? String {
        case "stream_event":
            if let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .textDelta(text)
            }
        case "assistant":
            let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let name = blocks.first(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
                return .toolUse(name.hasPrefix(toolPrefix) ? String(name.dropFirst(toolPrefix.count)) : name)
            }
        case "result":
            return .result(text: json["result"] as? String ?? "", isError: json["is_error"] as? Bool ?? false)
        default:
            break
        }
        return .other
    }

    /// Serializes to a single JSON line (control characters are escaped) ending in `\n`.
    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
