import Foundation

/// Device-local 14-day trial clock (PR1).
/// Stored in ThisDeviceOnly Keychain and must survive logout.
/// Account-level trial merge across devices is deferred to PR4.
enum DeviceTrialClock {
    static let durationDays = 14
    static let keychainAccount = "voxstudio.app-access.device-trial"

    struct Record: Codable, Equatable, Sendable {
        let startedAt: Date

        var endsAt: Date {
            startedAt.addingTimeInterval(TimeInterval(DeviceTrialClock.durationDays) * 86_400)
        }

        /// Reject local clock rollback earlier than the recorded start.
        func isValid(at date: Date) -> Bool {
            date >= startedAt
        }

        func snapshot(at date: Date = .now) -> AppAccessSnapshot? {
            guard isValid(at: date) else { return nil }
            let ends = endsAt
            // Device trial does not use a server offline lease; pin lease to trial end.
            return AppAccessSnapshot(
                license: .trial,
                trialEndsAt: ends,
                offlineValidUntil: ends
            )
        }
    }

    static func load(
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> Record? {
        guard let value = try read(),
              let data = Data(base64Encoded: value) else { return nil }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    /// Returns existing record or starts the trial at `date` (first Mac app use).
    @discardableResult
    static func ensureStarted(
        at date: Date = .now,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        },
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> Record {
        if let existing = try load(read: read) { return existing }
        let record = Record(startedAt: date)
        let data = try JSONEncoder().encode(record)
        try write(data.base64EncodedString())
        return record
    }

    static func activeSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        guard let record = try load(),
              let snapshot = record.snapshot(at: date),
              snapshot.policy(at: date) == .allowed else { return nil }
        return snapshot
    }

    static func currentSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        try load()?.snapshot(at: date)
    }
}

/// PR2 hook: Lifetime device credential presence (issue/verify not implemented in PR1).
enum LifetimeLocalCredential {
    static let keychainAccount = "voxstudio.app-access.lifetime-credential"

    /// PR1 stub: always false until PR2 signed-license verify lands.
    /// Must NOT treat any non-empty Keychain blob as Lifetime (unsigned/unverified → reject).
    /// Full issue/verify lands in PR2–PR3; device transfer / N-device caps in later PRs.
    static func isPresent(
        load: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount)
        }
    ) -> Bool {
        // Intentionally ignore `load` until cryptographic verify exists.
        // Any present blob is unsigned/unverified in PR1 and must not grant access.
        _ = try? load()
        return false
    }
}
