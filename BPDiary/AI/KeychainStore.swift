import Foundation
import Security

/// Хранение ключей доступа к сервисам ИИ в защищённом хранилище iPhone.
enum KeychainStore {
    private static let service = "BPDiary.AIKeys"

    static func key(for kind: AIProviderKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        return (value?.isEmpty ?? true) ? nil : value
    }

    @discardableResult
    static func setKey(_ value: String?, for kind: AIProviderKind) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func hasKey(for kind: AIProviderKind) -> Bool {
        key(for: kind) != nil
    }
}
