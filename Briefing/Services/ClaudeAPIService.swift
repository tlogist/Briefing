import Foundation

// Protocol so the API client doesn't care whether we're using an API key
// or OAuth — both just produce an authorization header.
protocol AuthProvider {
    func authHeader() async throws -> (name: String, value: String)
}

// API key auth: sends "x-api-key" header with the raw key.
struct APIKeyAuth: AuthProvider {
    func authHeader() async throws -> (name: String, value: String) {
        guard let key = KeychainService.load(key: KeychainService.Key.anthropicAPIKey),
              !key.isEmpty else {
            throw ClaudeAPIError.noAPIKey
        }
        return ("x-api-key", key)
    }
}

// MARK: - Chat Response

/// Parsed response from a chat API call, preserving raw content blocks
/// for multi-turn conversation history (needed for tool_use loops).
struct ChatResponse {
    let contentBlocks: [[String: Any]]
    let textContent: String
    let toolUses: [(id: String, name: String, input: [String: Any])]
    let stopReason: String  // "end_turn" or "tool_use"
}

// MARK: - API Service

// HTTP client for the Anthropic Messages API. Supports both single-shot
// prompts (for briefings) and multi-turn chat with tool use.
actor ClaudeAPIService {
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"
    private let authProvider: AuthProvider

    init(authProvider: AuthProvider = APIKeyAuth()) {
        self.authProvider = authProvider
    }

    /// Send a prompt to Claude and return the text response.
    func sendMessage(
        prompt: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 4096,
        systemPrompt: String? = nil
    ) async throws -> String {
        let response = try await sendChat(
            messages: [["role": "user", "content": prompt]],
            system: systemPrompt,
            model: model,
            maxTokens: maxTokens
        )
        guard !response.textContent.isEmpty else {
            throw ClaudeAPIError.emptyResponse
        }
        return response.textContent
    }

    /// Multi-turn chat with optional tool support.
    /// Returns the full response including raw content blocks (needed for
    /// tool_use conversation loops where you must echo blocks back).
    func sendChat(
        messages: [[String: Any]],
        system: String? = nil,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 1024,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil
    ) async throws -> ChatResponse {
        let auth = try await authProvider.authHeader()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]
        if let system = system {
            body["system"] = system
        }
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }
        // e.g. {"type": "tool", "name": "propose_actions"} to force a specific
        // tool call — the structured-output path for this raw-HTTP client
        if let toolChoice = toolChoice {
            body["tool_choice"] = toolChoice
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(auth.value, forHTTPHeaderField: auth.name)
        // Non-streaming: the API sends nothing until the full response is generated.
        // URLSession treats timeoutInterval as idle-between-packets, so the entire
        // generation time counts as "idle." Weekly briefings routinely need 50-60s;
        // 180s provides safe margin for heavy weeks or slow API conditions.
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: message)
            }
            throw ClaudeAPIError.apiError(
                statusCode: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode)"
            )
        }

        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeAPIError.invalidResponse
        }

        let stopReason = json["stop_reason"] as? String ?? "end_turn"

        let textContent = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")

        let toolUses = content.compactMap { block -> (id: String, name: String, input: [String: Any])? in
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else { return nil }
            return (id: id, name: name, input: input)
        }

        return ChatResponse(
            contentBlocks: content,
            textContent: textContent,
            toolUses: toolUses,
            stopReason: stopReason
        )
    }
}

// MARK: - Errors

enum ClaudeAPIError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Go to Settings to enter your Anthropic API key."
        case .invalidResponse:
            return "Invalid response from Claude API"
        case .emptyResponse:
            return "Claude returned an empty response"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}
