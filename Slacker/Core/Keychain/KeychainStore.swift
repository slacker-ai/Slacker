import Foundation
import Security

/// Thin wrapper over the macOS Keychain (generic-password items).
///
/// This is the ONLY place secrets live (Slack `xoxp-`/`xapp-` tokens + LLM API key).
/// Never UserDefaults, plist, SQLite, or logs (`docs/IMPLEMENTATION.md` §3, §5.4).
enum KeychainStore {
    /// Stable keys for singleton secrets. (Per-workspace Slack tokens use a computed account.)
    enum Key: String {
        case slackUserToken = "slack.user.token"   // legacy single-workspace token
        case llmAPIKey = "llm.api.key"
    }

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    /// Service namespace for all Slacker keychain items. Overridable for tests so they
    /// never touch the real app's stored secrets.
    static var service = "com.slacker.Slacker"

    // MARK: - Key-based API (singletons)

    static func set(_ value: String, for key: Key) throws { try setItem(value, account: key.rawValue) }
    static func get(_ key: Key) throws -> String? { try getItem(account: key.rawValue) }
    static func delete(_ key: Key) throws { try deleteItem(account: key.rawValue) }

    // MARK: - Per-workspace Slack tokens

    private static func tokenAccount(_ workspaceID: String) -> String { "slack.user.token.\(workspaceID)" }
    private static func appTokenAccount(_ workspaceID: String) -> String { "slack.app.token.\(workspaceID)" }

    static func setToken(_ token: String, workspaceID: String) throws {
        try setItem(token, account: tokenAccount(workspaceID))
    }

    /// Read a workspace's token, falling back to the legacy single-workspace token (so
    /// installs from before multi-workspace keep working until migrated).
    static func getToken(workspaceID: String) throws -> String? {
        if let token = try getItem(account: tokenAccount(workspaceID)) { return token }
        return try getItem(account: Key.slackUserToken.rawValue)
    }

    static func deleteToken(workspaceID: String) throws {
        let hadWorkspaceToken = try getItem(account: tokenAccount(workspaceID)) != nil
        try deleteItem(account: tokenAccount(workspaceID))
        // A pre-multi-workspace install may still be reading the singleton fallback.
        // Remove it only when this workspace had no dedicated item of its own.
        if !hadWorkspaceToken {
            try deleteItem(account: Key.slackUserToken.rawValue)
        }
    }

    static func setAppToken(_ token: String, workspaceID: String) throws {
        try setItem(token, account: appTokenAccount(workspaceID))
    }

    static func getAppToken(workspaceID: String) throws -> String? {
        try getItem(account: appTokenAccount(workspaceID))
    }

    static func deleteAppToken(workspaceID: String) throws {
        try deleteItem(account: appTokenAccount(workspaceID))
    }

    // MARK: - Generic-password primitives (account-keyed)

    private static func setItem(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.dataEncodingFailed }
        try? deleteItem(account: account)  // upsert: delete then add (idempotent)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func getItem(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncodingFailed
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func deleteItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
