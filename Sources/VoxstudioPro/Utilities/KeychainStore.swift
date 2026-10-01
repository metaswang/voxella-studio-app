import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum CredentialLoadResult: Equatable, Sendable {
    case present(String)
    case notConfigured
    case temporarilyUnavailable
    case configurationError
    case corrupted

    var value: String? {
        if case .present(let value) = self { return value }
        return nil
    }

    func get() throws -> String? {
        switch self {
        case .present(let value):
            return value
        case .notConfigured:
            return nil
        case .temporarilyUnavailable:
            throw KeychainStoreError.temporarilyUnavailable
        case .configurationError:
            throw KeychainStoreError.configurationError
        case .corrupted:
            throw KeychainStoreError.corrupted
        }
    }

    var statusMessage: String? {
        switch self {
        case .present, .notConfigured:
            nil
        case .temporarilyUnavailable:
            KeychainStoreError.temporarilyUnavailable.localizedDescription
        case .configurationError:
            KeychainStoreError.configurationError.localizedDescription
        case .corrupted:
            KeychainStoreError.corrupted.localizedDescription
        }
    }
}

enum KeychainStoreError: LocalizedError, Equatable, Sendable {
    case invalidValue
    case temporarilyUnavailable
    case configurationError
    case corrupted

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "The credential is empty."
        case .temporarilyUnavailable:
            "Secure credential storage is temporarily unavailable."
        case .configurationError:
            "This build is not configured for secure credential storage."
        case .corrupted:
            "The stored credential is unreadable. Enter it again."
        }
    }

    var isInteractionNotAllowed: Bool {
        self == .temporarilyUnavailable
    }
}

protocol CredentialStoreBackend: Sendable {
    func load(account: String, background: Bool) -> CredentialLoadResult
    func save(_ value: String, account: String, background: Bool) throws
    func delete(account: String, background: Bool) throws
}

struct SecurityItemClient: Sendable {
    var add: @Sendable (CFDictionary) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var delete: @Sendable (CFDictionary) -> OSStatus

    static let live = SecurityItemClient(
        add: { SecItemAdd($0, nil) },
        update: { SecItemUpdate($0, $1) },
        copyMatching: { SecItemCopyMatching($0, $1) },
        delete: { SecItemDelete($0) }
    )
}

enum KeychainStore {
    static let productionService = "com.voxella.studio.credentials.v3"
    static let service = credentialService(for: VoxellaAPIConfiguration.baseURL)

    /// Keep existing production credentials; other APIs get independent credentials,
    /// pending payments and offline entitlements in the same access group.
    static func credentialService(for apiBaseURL: URL) -> String {
        func normalized(_ url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if (components.scheme == "https" && components.port == 443)
                || (components.scheme == "http" && components.port == 80) {
                components.port = nil
            }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            while components.path.hasSuffix("/") { components.path.removeLast() }
            return components.string ?? url.absoluteString
        }
        let origin = normalized(apiBaseURL)
        guard origin != normalized(VoxellaAPIConfiguration.productionBaseURL) else {
            return productionService
        }
        let digest = SHA256.hash(data: Data(origin.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(productionService).api.\(digest)"
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideBackend: (any CredentialStoreBackend)?
    private static let defaultBackend: any CredentialStoreBackend = makeDefaultBackend()

    static var backend: any CredentialStoreBackend {
        lock.withLock { () -> any CredentialStoreBackend in
            overrideBackend ?? defaultBackend
        }
    }

    static var usesIsolatedMemoryStore: Bool {
        backend is MemoryCredentialStore
    }

    static func accessibility(background: Bool) -> CFString {
        background ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    static func loadProtected(account: String) -> CredentialLoadResult {
        backend.load(account: account, background: false)
    }

    static func saveProtected(_ value: String, account: String) throws {
        try save(value, account: account, background: false)
    }

    static func deleteProtected(account: String) throws {
        try backend.delete(account: account, background: false)
    }

    static func loadThisDeviceOnly(account: String) -> CredentialLoadResult {
        backend.load(account: account, background: true)
    }

    static func saveThisDeviceOnly(_ value: String, account: String) throws {
        try save(value, account: account, background: true)
    }

    static func deleteThisDeviceOnly(account: String) throws {
        try backend.delete(account: account, background: true)
    }

    static func testingInstallBackend(_ backend: (any CredentialStoreBackend)?) {
        lock.withLock { overrideBackend = backend }
    }

    static func testingResetMemoryStore() {
        if let memory = backend as? MemoryCredentialStore {
            memory.removeAll()
        }
    }

    private static func save(_ value: String, account: String, background: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainStoreError.invalidValue }
        try backend.save(trimmed, account: account, background: background)
    }

    private static func makeDefaultBackend() -> any CredentialStoreBackend {
        if let accessGroup = installedAccessGroup() {
            return DataProtectionCredentialStore(accessGroup: accessGroup, security: .live)
        }
        return MemoryCredentialStore()
    }

    static func installedAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) else { return nil }
        let groups = (entitlement as? [String]) ?? ((entitlement as? NSArray) as? [String])
        return groups?.first { !$0.isEmpty }
    }
}

final class MemoryCredentialStore: CredentialStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func load(account: String, background: Bool) -> CredentialLoadResult {
        _ = background
        return lock.withLock { () -> CredentialLoadResult in
            guard let value = items[account] else { return .notConfigured }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .corrupted }
            return .present(trimmed)
        }
    }

    func save(_ value: String, account: String, background: Bool) throws {
        _ = background
        lock.withLock { items[account] = value }
    }

    func delete(account: String, background: Bool) throws {
        _ = background
        lock.withLock { items[account] = nil }
    }

    func removeAll() {
        lock.withLock { items.removeAll() }
    }
}

struct DataProtectionCredentialStore: CredentialStoreBackend {
    let accessGroup: String
    let security: SecurityItemClient

    func load(account: String, background: Bool) -> CredentialLoadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = security.copyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return .corrupted }
            return .present(value)
        case errSecItemNotFound:
            return .notConfigured
        default:
            return mapLoadStatus(status)
        }
    }

    func save(_ value: String, account: String, background: Bool) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: KeychainStore.accessibility(background: background),
        ]
        let updateStatus = security.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw mapThrowingStatus(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let insertStatus = security.add(insert as CFDictionary)
        guard insertStatus == errSecSuccess else {
            throw mapThrowingStatus(insertStatus)
        }
    }

    func delete(account: String, background: Bool) throws {
        _ = background
        let status = security.delete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapThrowingStatus(status)
        }
    }

    func baseQuery(account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private func mapLoadStatus(_ status: OSStatus) -> CredentialLoadResult {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            .temporarilyUnavailable
        case errSecMissingEntitlement, errSecInvalidOwnerEdit, errSecNotAvailable:
            .configurationError
        case errSecDecode, errSecInvalidValue:
            .corrupted
        default:
            .temporarilyUnavailable
        }
    }

    private func mapThrowingStatus(_ status: OSStatus) -> KeychainStoreError {
        switch mapLoadStatus(status) {
        case .temporarilyUnavailable:
            .temporarilyUnavailable
        case .configurationError:
            .configurationError
        case .corrupted:
            .corrupted
        case .present, .notConfigured:
            .temporarilyUnavailable
        }
    }
}
