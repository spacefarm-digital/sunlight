import Foundation
import Security

/// The Anthropic API key Tell Sunlight uses, kept in the login keychain and nowhere else: not in the
/// defaults, the logs, the Diagnose report or a layout. Settings › General › Tell Sunlight writes it.
enum AgentKey {
    private static let service = "com.spacefarm.sunlight.anthropic"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var stored: String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static var isSet: Bool { stored != nil }

    /// Replaces the key; an empty one removes it. False if the keychain refused.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { Log.note("Tell Sunlight: couldn't save the API key (\(status))") }
        return status == errSecSuccess
    }

    static func remove() { SecItemDelete(query as CFDictionary) }

    /// What Settings shows of a saved key: its last four characters.
    static func masked(_ key: String) -> String { "••••" + key.suffix(4) }
}
