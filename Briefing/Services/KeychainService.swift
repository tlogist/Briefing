import Foundation
import Security

// Thin wrapper around the macOS Keychain for storing API keys and tokens.
// Uses kSecClassGenericPassword with a service name prefix so all Briefing
// credentials are grouped together in Keychain Access.
enum KeychainService {
    private static let serviceName = "com.ammaturo.Briefing"

    // MARK: - Store

    /// Save a string value to the Keychain under the given key.
    /// Overwrites any existing value for that key.
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete any existing item first (update = delete + add)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    // MARK: - Retrieve

    /// Read a string value from the Keychain. Returns nil if the key doesn't exist.
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    // MARK: - Delete

    /// Remove a value from the Keychain.
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
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
        case .encodingFailed: return "Failed to encode value for Keychain"
        case .saveFailed(let status): return "Keychain save failed (status: \(status))"
        }
    }
}
