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

// MARK: - API Service

// HTTP client for the Anthropic Messages API. Sends a single message and
// returns the text response. No streaming for now — briefings take ~10-15s
// and we show a progress indicator.
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
        model: String = "claude-sonnet-4-5-20250929",
        maxTokens: Int = 4096,
        systemPrompt: String? = nil
    ) async throws -> String {
        let auth = try await authProvider.authHeader()

        // Build the request body
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if let system = systemPrompt {
            body["system"] = system
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(auth.value, forHTTPHeaderField: auth.name)
        // Generous timeout — briefings with full context can take a while
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        // Parse the response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.invalidResponse
        }

        // Check for API errors
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

        // Extract text from the content blocks
        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeAPIError.invalidResponse
        }

        let textBlocks = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }

        guard !textBlocks.isEmpty else {
            throw ClaudeAPIError.emptyResponse
        }

        return textBlocks.joined(separator: "\n")
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
