import Foundation
import Testing
import Security
@testable import PalmierPro

@Suite struct CredentialMigrationTests {
    @Test func accessibilityPreservesDeviceBindingAndBackgroundPolicy() {
        #expect(KeychainStore.accessibility(background: false) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(KeychainStore.accessibility(background: true) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    @Test @MainActor func byokModelCanBeSelectedBeforeCredentialsAreLoaded() throws {
        let suite = "CredentialMigrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AgentService(userDefaults: defaults)
        #expect(service.canSelectModel(.terra, transport: .byok))
        #expect(service.canSelectModel(.sonnet5, transport: .byok))
    }
    private final class Store {
        var record: CredentialMigration.Record?
        var legacy: String? = "legacy"
        var failsCleanup = false
        var failsWrite = false
        var legacyReads = 0
        enum Failure: Error { case storage }
        var migration: CredentialMigration {
            CredentialMigration(
                read: { self.record },
                write: {
                    if self.failsWrite { throw Failure.storage }
                    self.record = $0
                },
                readLegacy: { self.legacyReads += 1; return self.legacy },
                removeLegacy: {
                    if self.failsCleanup { throw Failure.storage }
                    self.legacy = nil
                }
            )
        }
    }

    @Test func deletionFailureCannotResurrectLegacyCredential() throws {
        let store = Store()
        store.failsCleanup = true
        #expect(throws: Store.Failure.self) { try store.migration.delete() }
        #expect(try store.migration.load() == nil)
        #expect(store.legacyReads == 0)
        #expect(store.legacy == "legacy")
    }

    @Test func failedDestinationWritePreservesLegacyCredential() {
        let store = Store()
        store.failsWrite = true
        #expect(throws: Store.Failure.self) { try store.migration.load() }
        #expect(store.record == nil)
        #expect(store.legacy == "legacy")
    }

    @Test func successfulMigrationRemovesLegacyAndReadsItOnce() throws {
        let store = Store()
        #expect(try store.migration.load() == "legacy")
        #expect(try store.migration.load() == "legacy")
        #expect(store.legacy == nil)
        #expect(store.legacyReads == 1)
    }

    @Test func savedValueWinsAfterPartialCleanupFailure() throws {
        let store = Store()
        store.failsCleanup = true
        #expect(throws: Store.Failure.self) { try store.migration.save("new") }
        #expect(try store.migration.load() == "new")
    }

    @Test func explicitSaveReplacesDeletionMarker() throws {
        let store = Store()
        try store.migration.delete()
        try store.migration.save("replacement")
        #expect(try store.migration.load() == "replacement")
    }
}
