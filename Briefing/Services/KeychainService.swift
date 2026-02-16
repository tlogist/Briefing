import Foundation

// Credential storage for API keys and tokens.
//
// Currently uses UserDefaults because ad-hoc code signing (CODE_SIGN_IDENTITY: "-")
// triggers Keychain access prompts on every read. When the app is properly signed
// for distribution, switch this to use the Security framework (SecItemAdd, etc.)
// for proper encrypted storage.
//
// TODO: Switch to real Keychain when app is code-signed for distribution.
enum KeychainService {
    private static let prefix = "com.ammaturo.Briefing."

    // MARK: - Store

    /// Save a string value under the given key.
    static func save(key: String, value: String) throws {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    // MARK: - Retrieve

    /// Read a string value. Returns nil if the key doesn't exist.
    static func load(key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    // MARK: - Delete

    /// Remove a value.
    static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    // MARK: - Convenience

    /// Well-known keys for credentials stored by Briefing.
    enum Key {
        static let anthropicAPIKey = "anthropic-api-key"
        static let oauthAccessToken = "oauth-access-token"
        static let oauthRefreshToken = "oauth-refresh-token"
    }
}

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode value"
        case .saveFailed(let status): return "Save failed (status: \(status))"
        }
    }
}
