import Foundation

actor AppAccessCache {
    // Account-bound offline lease cache. Cleared on logout.
    // Device-local trial (DeviceTrialClock) and Lifetime credential (LifetimeLocalCredential) use separate
    // ThisDeviceOnly keys and must not be cleared here on logout.
    static let shared = AppAccessCache()
    private var writeRevision: UInt64 = 0
    private let readValue: @Sendable () throws -> String?
    private let writeValue: @Sendable (String) throws -> Void
    private let deleteValue: @Sendable () throws -> Void

    init(
        read: @escaping @Sendable () throws -> String? = { try KeychainStore.loadThisDeviceOnly(account: "voxstudio.app-access.lifetime").get() },
        write: @escaping @Sendable (String) throws -> Void = { try KeychainStore.saveThisDeviceOnly($0, account: "voxstudio.app-access.lifetime") },
        delete: @escaping @Sendable () throws -> Void = { try KeychainStore.deleteThisDeviceOnly(account: "voxstudio.app-access.lifetime") }
    ) {
        readValue = read
        writeValue = write
        deleteValue = delete
    }

    struct Entry: Codable, Sendable {
        let account: AccountResponse
        let access: AppAccessSnapshot
        let verifiedAt: Date

        func isValid(at date: Date) -> Bool {
            access.policy(at: date) == .allowed && date >= verifiedAt &&
                access.offlineValidUntil.map { date < $0 && $0.timeIntervalSince(verifiedAt) <= TimeInterval(LifetimeDeviceLicense.leaseDays) * 86400 + 60 } == true
        }
    }

    func save(account: AccountResponse, access: AppAccessSnapshot, revision: UInt64) throws {
        guard revision >= writeRevision else { return }
        writeRevision = revision
        guard access.policy() == .allowed, access.offlineValidUntil != nil else {
            try clear(revision: revision)
            return
        }
        let data = try JSONEncoder().encode(Entry(account: account, access: access, verifiedAt: .now))
        try writeValue(data.base64EncodedString())
    }

    func load() throws -> Entry? {
        guard let value = try readValue(),
              let data = Data(base64Encoded: value) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        return entry.isValid(at: .now) ? entry : nil
    }

    func clear(revision: UInt64) throws {
        guard revision >= writeRevision else { return }
        writeRevision = revision
        try deleteValue()
    }
}
