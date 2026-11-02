import Foundation

/// Claude's Messages API over plain HTTPS: there's no Swift SDK. Messages and content blocks stay as
/// the JSON the API sent (`[String: Any]`), so thinking and fallback blocks go back exactly as they came,
/// which the API requires of a conversation that continues.
struct ClaudeClient {
    /// Sonnet: a request is a handful of quick tool calls, and the bar is waited on.
    static let model = "claude-sonnet-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// `fallbacks: "default"`: a request a safety check declines is run again on the model Anthropic
    /// recommends for that kind of decline, instead of ending the task.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Off unless `defaults write com.spacefarm.sunlight TellSunlightFallbacks -bool true`: every turn
    /// took 10-12 s however short, and this is being ruled out as the cause.
    static var fallbacks: Bool { UserDefaults.standard.bool(forKey: "TellSunlightFallbacks") }

    /// Low: each turn is a short tool pick, and every second of a round trip is waited on at the bar.
    /// `defaults write com.spacefarm.sunlight TellSunlightEffort medium` (or high) for harder requests.
    static var effort: String {
        let chosen = UserDefaults.standard.string(forKey: "TellSunlightEffort") ?? ""
        return ["low", "medium", "high"].contains(chosen) ? chosen : "low"
    }

    let key: String

    struct Reply {
        /// The assistant's content blocks, as sent: append them to the conversation unchanged.
        let content: [[String: Any]]
        let stopReason: String
        let inputTokens: Int
        let outputTokens: Int
        /// Input read from the cache: the system prompt, tools and earlier turns.
        var cachedTokens = 0

        var text: String {
            content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var toolUses: [(id: String, name: String, input: [String: Any])] {
            content.compactMap { b in
                guard b["type"] as? String == "tool_use", let id = b["id"] as? String, let name = b["name"] as? String else { return nil }
                return (id, name, b["input"] as? [String: Any] ?? [:])
            }
        }
    }

    enum Failure: LocalizedError {
        case key, busy, refused(String), http(Int, String), malformed

        var errorDescription: String? {
            switch self {
            case .key: return "The API key was refused. Check it in Settings › General › Tell Sunlight."
            case .busy: return "Claude is busy right now. Try again in a moment."
            case .refused(let why): return "Claude declined this request\(why.isEmpty ? "" : " (\(why))")."
            case .http(let code, let message): return "The request failed (\(code))\(message.isEmpty ? "" : ": \(message)")."
            case .malformed: return "Claude's answer couldn't be read."
            }
        }
    }

    /// The request body: everything but the key. Kept apart so tests can read it.
    static func body(system: String, tools: [[String: Any]], messages: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "tools": tools,
            "messages": messages,
            "output_config": ["effort": effort],
            // The tools and the system prompt are the same on every turn: cached after the first.
            "cache_control": ["type": "ephemeral"],
        ]
        if fallbacks { body["fallbacks"] = "default" }
        return body
    }

    func send(system: String, tools: [[String: Any]], messages: [[String: Any]]) async throws -> Reply {
        var request = URLRequest(url: ClaudeClient.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if ClaudeClient.fallbacks { request.setValue(ClaudeClient.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ClaudeClient.body(system: system, tools: tools, messages: messages))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? ""
            switch status {
            case 401, 403: throw Failure.key
            case 429, 529: throw Failure.busy
            default: throw Failure.http(status, message)
            }
        }
        guard let json, let content = json["content"] as? [[String: Any]], let stop = json["stop_reason"] as? String else {
            throw Failure.malformed
        }
        if stop == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw Failure.refused(details?["category"] as? String ?? "")
        }
        let usage = json["usage"] as? [String: Any]
        return Reply(content: content, stopReason: stop,
                     inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0,
                     cachedTokens: usage?["cache_read_input_tokens"] as? Int ?? 0)
    }
}
