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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let key = cacheKey(service, account)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
            remember(value, key)
            return value
        case errSecItemNotFound:
            remember(nil, key)
            return nil
        default:
            // A locked device (errSecInteractionNotAllowed) or a transient
            // Keychain failure is not an absent credential. Answer with the
            // value last read so callers never mistake it for a revocation.
            cacheLock.lock(); defer { cacheLock.unlock() }
            return cache[key]
        }
    }

    /// Removes an item; the only path besides an empty `set` that forgets it.
    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        remember(nil, cacheKey(service, account))
    }

    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()
    private static func cacheKey(_ service: String, _ account: String) -> String { service + "\u{1F}" + account }
    private static func remember(_ value: String?, _ key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key] = value
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
            remember(nil, cacheKey(service, account))
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
        remember(value, cacheKey(service, account))
    }
}

enum KeychainError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "The iPad could not store this credential securely." }
}
