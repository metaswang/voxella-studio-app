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
    private static let migrationLock = NSLock()

    static func accessibility(background: Bool) -> CFString {
        background ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private enum Backend {
        case dataProtection
        case login
    }

    private static let preferredBackend: Backend = {
        guard let task = SecTaskCreateFromSelf(nil) else { return .login }
        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        )
        return entitlement == nil ? .login : .dataProtection
    }()

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
        guard !trimmed.isEmpty else {
            throw KeychainStoreError.invalidValue
        }
        try migrationLock.withLock {
            try migration(account: account).save(trimmed)
        }
    }

    static func loadProtected(account: String) throws -> String? {
        try migrationLock.withLock { try migration(account: account).load() }
    }

    static func loadProtected(account: String, legacyAccount: String) throws -> String? {
        try migrationLock.withLock {
            let current = migration(account: account)
            if let record = try current.read() { return record.value }
            if let value = try current.load() { return value }
            let legacy = migration(account: legacyAccount)
            guard let value = try legacy.load() else { return nil }
            try current.save(value)
            try legacy.delete()
            return value
        }
    }

    static func containsProtected(account: String) throws -> Bool {
        try loadProtected(account: account) != nil
    }

    static func deleteProtected(account: String) throws {
        try migrationLock.withLock { try migration(account: account).delete() }
    }

    static func saveThisDeviceOnly(_ value: String, account: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeychainStoreError.invalidValue }
        try migrationLock.withLock {
            try migration(account: account, background: true).save(value)
        }
    }

    static func loadThisDeviceOnly(account: String) throws -> String? {
        try migrationLock.withLock { try migration(account: account, background: true).load() }
    }

    static func deleteThisDeviceOnly(account: String) throws {
        try migrationLock.withLock { try migration(account: account, background: true).delete() }
    }

    private static func migration(account: String, background: Bool = false) -> CredentialMigration {
        let service = protectedService + ".v2"
        return CredentialMigration(
            read: {
                guard let encoded = try loadItem(account: account, backend: preferredBackend, service: service) else { return nil }
                return try JSONDecoder().decode(CredentialMigration.Record.self, from: Data(encoded.utf8))
            },
            write: { record in
                let data = try JSONEncoder().encode(record)
                try upsert(data, account: account, backend: preferredBackend, service: service, background: background)
            },
            readLegacy: {
                let protectedValue: String?
                do {
                    protectedValue = try loadItem(account: account, backend: .dataProtection)
                } catch KeychainStoreError.status(errSecMissingEntitlement) {
                    protectedValue = nil
                }
                return try protectedValue ?? loadItem(account: account, backend: .login)
            },
            removeLegacy: {
                try deleteItem(account: account, backend: .login)
                do {
                    try deleteItem(account: account, backend: .dataProtection)
                } catch KeychainStoreError.status(errSecMissingEntitlement) where preferredBackend == .login {
                    Log.app.warning("Legacy credential cleanup unavailable: missing data-protection entitlement; authoritative record retained")
                }
            }
        )
    }

    private static func upsert(_ data: Data, account: String, backend: Backend, service: String, background: Bool) throws {
        var query = protectedQuery(account: account, backend: backend, service: service)
        if backend == .login, background {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var attributes: [String: Any] = [kSecValueData as String: data]
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = accessibility(background: background)
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.status(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainStoreError.status(insertStatus)
        }
    }

    private static func loadItem(account: String, backend: Backend, service: String = protectedService) throws -> String? {
        var query = protectedQuery(account: account, backend: backend, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // A stale login-keychain ACL must not block app launch with repeated modal
        // authorization prompts. Explicit credential saves can still repair the item.
        if backend == .login {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
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

    private static func deleteItem(account: String, backend: Backend) throws {
        let status = SecItemDelete(protectedQuery(account: account, backend: backend) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    private static func protectedQuery(account: String, backend: Backend, service: String = protectedService) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }
}

extension KeychainStoreError {
    var isInteractionNotAllowed: Bool {
        if case .status(errSecInteractionNotAllowed) = self { return true }
        return false
    }
}
