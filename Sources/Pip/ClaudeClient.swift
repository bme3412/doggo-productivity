import Foundation

enum ClaudeError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic API key in Doggo’s Settings first."
        case .http(let code, let body): return "Claude API error \(code): \(body.prefix(300))"
        case .badResponse(let why): return "Unexpected response from Claude: \(why)"
        }
    }
}

/// Minimal client for the Anthropic Messages API.
enum ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static func send(system: String,
                             user: String,
                             maxTokens: Int,
                             outputSchema: [String: Any]? = nil) async throws -> (text: String, stopReason: String?) {
        guard let key = Prefs.apiKey else { throw ClaudeError.noKey }

        var body: [String: Any] = [
            "model": Prefs.claudeModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        if let outputSchema {
            let format: [String: Any] = ["type": "json_schema", "schema": outputSchema]
            body["output_config"] = ["format": format]
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClaudeError.badResponse("no content")
        }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        return (text, json["stop_reason"] as? String)
    }

    static func jsonObject(system: String, user: String, schema: [String: Any], maxTokens: Int = 8000) async throws -> [String: Any] {
        let response = try await send(system: system, user: user, maxTokens: maxTokens, outputSchema: schema)
        switch response.stopReason {
        case "refusal": throw ClaudeError.badResponse("the request was declined")
        case "max_tokens", "model_context_window_exceeded":
            throw ClaudeError.badResponse("the structured reply was cut short")
        default: break
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any] else {
            throw ClaudeError.badResponse("no valid structured reply")
        }
        return object
    }

    static func text(system: String, user: String, maxTokens: Int = 1500) async throws -> String {
        try await send(system: system, user: user, maxTokens: maxTokens).text
    }
}
