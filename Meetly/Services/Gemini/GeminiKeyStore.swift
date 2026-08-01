import Foundation
import Security

enum GeminiKeyStore {
    private static let service = "com.meetly.gemini-api-key"
    private static let account = "default"

    static var apiKey: String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func setAPIKey(_ key: String?) {
        deleteAPIKey()

        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(key.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func migrateFromDotEnvIfNeeded() {
        guard apiKey == nil else { return }

        guard let envKey = DotEnv.value(for: "GEMINI_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !envKey.isEmpty,
              envKey != "<your-key-here>",
              envKey != "YOUR_GEMINI_API_KEY" else {
            return
        }

        setAPIKey(envKey)
    }

    private static func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
