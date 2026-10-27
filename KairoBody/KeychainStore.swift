import Foundation
import Security

enum KeychainStore {
    struct Operations {
        var update: ([String: Any], [String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var delete: ([String: Any]) -> OSStatus
        static let system = Operations(
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) })
    }
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Writes without ever replacing an existing item with an empty value.
    static func seed(_ value: String, service: String, account: String) {
        guard !value.isEmpty else { return }
        guard read(service: service, account: account).map(\.isEmpty) ?? true else { return }
        set(value, service: service, account: account)
    }

    static func set(_ value: String, service: String, account: String, operations: Operations = .system) {
        if value.isEmpty {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecAttrAccount as String: account]
            _ = operations.delete(query)
        } else {
            try? setChecked(value, service: service, account: account, operations: operations)
        }
    }

    static func setChecked(_ value: String, service: String, account: String, operations: Operations = .system) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = operations.update(query, update)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = operations.add(add)
        }
        guard status == errSecSuccess else { throw KeychainError.writeFailed }
    }
}

enum KeychainError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "The iPad could not store this credential securely." }
}
