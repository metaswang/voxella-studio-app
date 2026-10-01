import Foundation
import Security
import Testing
@testable import VoxstudioPro

@Suite("API credential isolation")
struct APICredentialIsolationTests {
    @Test func productionKeepsExistingCredentials() {
        for origin in ["https://voxstudio.me", "https://VOXSTUDIO.me:443/"] {
            #expect(KeychainStore.credentialService(for: URL(string: origin)!)
                == "com.voxella.studio.credentials.v3")
        }
    }

    @Test func localAndProductionPaymentsAndLicensesCannotShareCredentials() {
        let local = KeychainStore.credentialService(for: URL(string: "http://localhost:5173")!)
        let production = KeychainStore.credentialService(for: URL(string: "https://voxstudio.me")!)
        #expect(local != production)
        #expect(local == KeychainStore.credentialService(for: URL(string: "http://LOCALHOST:5173/")!))
        #expect(local != KeychainStore.credentialService(for: URL(string: "http://localhost:8000")!))
        #expect(local != KeychainStore.credentialService(for: URL(string: "https://localhost:5173")!))
    }

    @Test func apiPrefixesAreIsolated() {
        let origin = URL(string: "https://example.com")!
        let prefixed = URL(string: "https://example.com/staging")!
        #expect(KeychainStore.credentialService(for: origin) != KeychainStore.credentialService(for: prefixed))
    }
}

@Suite(.serialized)
struct KeychainStoreTests {
    @Test func accessibilityPreservesDeviceBindingAndBackgroundPolicy() {
        #expect(KeychainStore.accessibility(background: false) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(KeychainStore.accessibility(background: true) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(KeychainStore.service == "com.voxella.studio.credentials.v3")
    }

    @Test @MainActor func byokModelCanBeSelectedBeforeCredentialsAreLoaded() throws {
        let suite = "KeychainStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AgentService(userDefaults: defaults)
        #expect(service.canSelectModel(.terra, transport: .byok))
        #expect(service.canSelectModel(.sonnet5, transport: .byok))
    }

    @Test func memoryStoreCreateReadOverwriteDelete() throws {
        let store = MemoryCredentialStore()
        KeychainStore.testingInstallBackend(store)
        defer { KeychainStore.testingInstallBackend(nil) }

        #expect(KeychainStore.loadProtected(account: "api") == .notConfigured)
        try KeychainStore.saveProtected("first", account: "api")
        #expect(try KeychainStore.loadProtected(account: "api").get() == "first")
        try KeychainStore.saveProtected("second", account: "api")
        #expect(try KeychainStore.loadProtected(account: "api").get() == "second")
        try KeychainStore.deleteProtected(account: "api")
        #expect(KeychainStore.loadProtected(account: "api") == .notConfigured)
    }

    @Test func emptySaveIsRejectedAndDoesNotReportSuccess() {
        let store = MemoryCredentialStore()
        KeychainStore.testingInstallBackend(store)
        defer { KeychainStore.testingInstallBackend(nil) }

        #expect(throws: KeychainStoreError.invalidValue) {
            try KeychainStore.saveProtected("   ", account: "api")
        }
        #expect(KeychainStore.loadProtected(account: "api") == .notConfigured)
    }

    @Test func concurrentReadsAndWritesLeaveAConsistentValue() async throws {
        let store = MemoryCredentialStore()
        KeychainStore.testingInstallBackend(store)
        defer { KeychainStore.testingInstallBackend(nil) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try KeychainStore.saveThisDeviceOnly("value-\(index)", account: "shared")
                    _ = KeychainStore.loadThisDeviceOnly(account: "shared")
                }
            }
            try await group.waitForAll()
        }
        let result = try #require(try KeychainStore.loadThisDeviceOnly(account: "shared").get())
        #expect(result.hasPrefix("value-"))
    }

    @Test func unavailableAndMissingEntitlementResultsStayDistinct() throws {
        let backend = ResultCredentialStore(result: .temporarilyUnavailable)
        KeychainStore.testingInstallBackend(backend)
        defer { KeychainStore.testingInstallBackend(nil) }
        #expect(KeychainStore.loadProtected(account: "api") == .temporarilyUnavailable)
        #expect(throws: KeychainStoreError.temporarilyUnavailable) {
            try KeychainStore.loadProtected(account: "api").get()
        }

        backend.result = .configurationError
        #expect(KeychainStore.loadProtected(account: "api") == .configurationError)
        #expect(throws: KeychainStoreError.configurationError) {
            try KeychainStore.saveProtected("secret", account: "api")
        }
    }

    @Test func corruptedDataIsNotTreatedAsMissing() {
        let backend = ResultCredentialStore(result: .corrupted)
        KeychainStore.testingInstallBackend(backend)
        defer { KeychainStore.testingInstallBackend(nil) }
        #expect(KeychainStore.loadThisDeviceOnly(account: "trial") == .corrupted)
        #expect(throws: KeychainStoreError.corrupted) {
            try KeychainStore.loadThisDeviceOnly(account: "trial").get()
        }
    }

    @Test func dataProtectionQueriesNeverTouchLegacyNamespaces() throws {
        let security = RecordingSecurityClient()
        let store = DataProtectionCredentialStore(
            accessGroup: "TEAM.com.voxella.studio",
            security: security.client
        )
        _ = store.load(account: "refresh", background: true)
        try store.save("token", account: "refresh", background: true)
        try store.delete(account: "refresh", background: true)

        #expect(!security.services.isEmpty)
        #expect(security.services.allSatisfy { $0 == KeychainStore.service })
        #expect(!security.services.contains("com.voxella.studio.credentials"))
        #expect(!security.services.contains("com.voxella.studio.credentials.v2"))
        #expect(security.usedDataProtection.allSatisfy { $0 })
        #expect(security.usedAuthenticationUIFail.allSatisfy { $0 })
        #expect(security.accessGroups.allSatisfy { $0 == "TEAM.com.voxella.studio" })
    }

    @Test func missingEntitlementStatusMapsToConfigurationError() {
        let security = RecordingSecurityClient(copyStatus: errSecMissingEntitlement)
        let store = DataProtectionCredentialStore(
            accessGroup: "TEAM.com.voxella.studio",
            security: security.client
        )
        #expect(store.load(account: "refresh", background: true) == .configurationError)
    }

    @Test func interactionNotAllowedMapsToTemporarilyUnavailableWithoutFallback() {
        let security = RecordingSecurityClient(copyStatus: errSecInteractionNotAllowed)
        let store = DataProtectionCredentialStore(
            accessGroup: "TEAM.com.voxella.studio",
            security: security.client
        )
        #expect(store.load(account: "refresh", background: true) == .temporarilyUnavailable)
        #expect(security.services == [KeychainStore.service])
    }
}

private final class ResultCredentialStore: CredentialStoreBackend, @unchecked Sendable {
    var result: CredentialLoadResult
    var saveError: KeychainStoreError?

    init(result: CredentialLoadResult, saveError: KeychainStoreError? = nil) {
        self.result = result
        self.saveError = saveError
    }

    func load(account: String, background: Bool) -> CredentialLoadResult { result }

    func save(_ value: String, account: String, background: Bool) throws {
        _ = value
        _ = account
        _ = background
        switch result {
        case .temporarilyUnavailable:
            throw KeychainStoreError.temporarilyUnavailable
        case .configurationError:
            throw KeychainStoreError.configurationError
        case .corrupted:
            throw KeychainStoreError.corrupted
        case .present, .notConfigured:
            if let saveError { throw saveError }
        }
    }

    func delete(account: String, background: Bool) throws {
        if let saveError { throw saveError }
    }
}

private final class RecordingSecurityClient: @unchecked Sendable {
    var services: [String] = []
    var accessGroups: [String] = []
    var usedDataProtection: [Bool] = []
    var usedAuthenticationUIFail: [Bool] = []
    var copyStatus: OSStatus

    init(copyStatus: OSStatus = errSecItemNotFound) {
        self.copyStatus = copyStatus
    }

    var client: SecurityItemClient {
        SecurityItemClient(
            add: { [weak self] query in
                self?.record(query)
                return errSecSuccess
            },
            update: { [weak self] query, _ in
                self?.record(query)
                return errSecItemNotFound
            },
            copyMatching: { [weak self] query, _ in
                self?.record(query)
                return self?.copyStatus ?? errSecItemNotFound
            },
            delete: { [weak self] query in
                self?.record(query)
                return errSecItemNotFound
            }
        )
    }

    private func record(_ query: CFDictionary) {
        let dictionary = query as NSDictionary
        if let service = dictionary[kSecAttrService] as? String {
            services.append(service)
        }
        if let group = dictionary[kSecAttrAccessGroup] as? String {
            accessGroups.append(group)
        }
        usedDataProtection.append((dictionary[kSecUseDataProtectionKeychain] as? Bool) == true)
        usedAuthenticationUIFail.append(
            (dictionary[kSecUseAuthenticationUI] as? String) == (kSecUseAuthenticationUIFail as String)
        )
    }
}
