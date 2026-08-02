import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case invalidValue
    case unexpectedData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "The credential is empty."
        case .unexpectedData:
            "The credential stored in Keychain is invalid."
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}

enum KeychainStore {
    private static let legacyService: String = Bundle.main.bundleIdentifier ?? "com.voxella.studio"
    private static let protectedService = "com.voxella.studio.credentials"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attrs) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveProtected(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainStoreError.invalidValue
        }
        do {
            try upsert(data, account: account, backend: .dataProtection)
            // A development build may previously have stored the same credential
            // in the login keychain. Once a provisioned build can use the data
            // protection keychain, keep only the stronger copy.
            try? deleteItem(account: account, backend: .login)
        } catch let error as KeychainStoreError where error.isMissingEntitlement {
            // Ad-hoc macOS builds have no provisioning-profile-authorized keychain
            // access group. The login keychain remains encrypted and is the only
            // entitlement-free Keychain Services implementation available to them.
            try upsert(data, account: account, backend: .login)
        }
    }

    static func loadProtected(account: String) throws -> String? {
        do {
            if let value = try loadItem(account: account, backend: .dataProtection) {
                return value
            }
            guard let value = try loadItem(account: account, backend: .login) else {
                return nil
            }
            // Best-effort migration when an app that was previously ad-hoc signed
            // is later launched with a valid provisioning profile.
            try? saveProtected(value, account: account)
            return value
        } catch let error as KeychainStoreError where error.isMissingEntitlement {
            return try loadItem(account: account, backend: .login)
        }
    }

    static func containsProtected(account: String) throws -> Bool {
        do {
            return try containsItem(account: account, backend: .dataProtection)
                || containsItem(account: account, backend: .login)
        } catch let error as KeychainStoreError where error.isMissingEntitlement {
            return try containsItem(account: account, backend: .login)
        }
    }

    static func deleteProtected(account: String) throws {
        do {
            try deleteItem(account: account, backend: .dataProtection)
        } catch let error as KeychainStoreError where error.isMissingEntitlement {
            // Expected for an ad-hoc build; still remove the login-keychain copy.
        }
        try deleteItem(account: account, backend: .login)
    }

    private enum Backend {
        case dataProtection
        case login
    }

    private static func upsert(_ data: Data, account: String, backend: Backend) throws {
        let query = protectedQuery(account: account, backend: backend)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.status(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        if backend == .dataProtection {
            insert[kSecAttrSynchronizable as String] = false
        }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainStoreError.status(insertStatus)
        }
    }

    private static func loadItem(account: String, backend: Backend) throws -> String? {
        var query = protectedQuery(account: account, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw KeychainStoreError.unexpectedData
        }
        return value
    }

    private static func containsItem(account: String, backend: Backend) throws -> Bool {
        var query = protectedQuery(account: account, backend: backend)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        return true
    }

    private static func deleteItem(account: String, backend: Backend) throws {
        let status = SecItemDelete(
            protectedQuery(account: account, backend: backend) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    private static func protectedQuery(account: String, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: protectedService,
            kSecAttrAccount as String: account,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

private extension KeychainStoreError {
    var isMissingEntitlement: Bool {
        if case .status(errSecMissingEntitlement) = self { return true }
        return false
    }
}
