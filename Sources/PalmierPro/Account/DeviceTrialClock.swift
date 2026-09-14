import Foundation

/// Device-local 14-day trial clock (PR1.1).
/// Keychain stores a signed Ed25519 JWT as the authority (not plaintext startedAt).
/// Offline first-run may store a provisional local 14d clock until register succeeds.
/// Account-level trial merge across devices is deferred to PR4.
enum DeviceTrialClock {
    static let durationDays = 14
    static let keychainAccount = "voxstudio.app-access.device-trial"
    static let offlineGrace: TimeInterval = 7 * 86_400
    static let verifyInterval: TimeInterval = 24 * 3_600
    static let verifyRetryInterval: TimeInterval = 5 * 60
    static let expiryLead: TimeInterval = 24 * 3_600

    struct Envelope: Codable, Equatable, Sendable {
        let token: String
        let fingerprint: String
        let lastVerifiedAt: Date
    }

    struct Record: Equatable, Sendable {
        let envelope: Envelope
        let claims: DeviceTrialLicense.Claims

        var startedAt: Date { claims.startedAt }
        var endsAt: Date { claims.endsAt }
        var lastVerifiedAt: Date { envelope.lastVerifiedAt }

        /// Reject local clock rollback earlier than started_at / iat.
        /// Allows ~5 min skew on iat so client clock behind server does not invalidate.
        func isChronologicallyValid(at date: Date) -> Bool {
            let iatSkewTolerance: TimeInterval = 5 * 60
            // Client clock may lag server iat/started_at by a few minutes.
            return date >= claims.startedAt.addingTimeInterval(-iatSkewTolerance)
                && date >= claims.issuedAt.addingTimeInterval(-iatSkewTolerance)
        }

        func graceEndsAt(at date: Date = .now) -> Date {
            min(claims.endsAt, envelope.lastVerifiedAt.addingTimeInterval(DeviceTrialClock.offlineGrace))
        }

        func evaluation(at date: Date = .now) -> Evaluation {
            guard isChronologicallyValid(at: date) else { return .invalid }
            if claims.endsAt <= date { return .expired }
            // Offline grace is soft: mid-trial local recording stays allowed; refreshIsDue
            // forces a verify attempt. Hard block only after endsAt.
            return .allowed
        }

        func snapshot(at date: Date = .now) -> AppAccessSnapshot? {
            guard isChronologicallyValid(at: date) else { return nil }
            return AppAccessSnapshot(
                license: .trial,
                trialEndsAt: claims.endsAt,
                offlineValidUntil: graceEndsAt(at: date)
            )
        }

        func refreshIsDue(at date: Date = .now, lastAttempt: Date? = nil) -> Bool {
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < DeviceTrialClock.verifyRetryInterval {
                return false
            }
            // Past offline grace: still allow locally, but prefer online verify when reachable.
            if graceEndsAt(at: date) <= date { return true }
            if date.addingTimeInterval(DeviceTrialClock.expiryLead) >= claims.endsAt { return true }
            return date.timeIntervalSince(envelope.lastVerifiedAt) >= DeviceTrialClock.verifyInterval
        }
    }

    enum Evaluation: Equatable, Sendable {
        case allowed
        case expired
        case verificationRequired
        case invalid
    }

    static func load(
        fingerprint: String? = nil,
        publicKeyRaw: Data = DeviceTrialLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> Record? {
        guard let value = try read(),
              let data = Data(base64Encoded: value) else { return nil }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            let liveFingerprint = fingerprint ?? (try? DeviceFingerprint.current()) ?? envelope.fingerprint
            let claims = try DeviceTrialLicense.verify(
                envelope.token,
                fingerprint: liveFingerprint,
                publicKeyRaw: publicKeyRaw
            )
            return Record(envelope: envelope, claims: claims)
        }
        return nil
    }

    /// Plaintext PR1 startedAt, used only as a register hint. Not authority.
    static func legacyStartedAtHint(
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        }
    ) -> Date? {
        guard let value = try? read(),
              let data = Data(base64Encoded: value),
              let legacy = try? JSONDecoder().decode(LegacyRecord.self, from: data)
        else { return nil }
        return legacy.startedAt
    }

    static func store(
        token: String,
        fingerprint: String,
        verifiedAt: Date = .now,
        publicKeyRaw: Data = DeviceTrialLicense.publicKeyRaw,
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> Record {
        let claims = try DeviceTrialLicense.verify(token, fingerprint: fingerprint, publicKeyRaw: publicKeyRaw)
        let envelope = Envelope(token: token, fingerprint: fingerprint, lastVerifiedAt: verifiedAt)
        let data = try JSONEncoder().encode(envelope)
        try write(data.base64EncodedString())
        // Signed token supersedes any provisional local clock.
        try? clearProvisional()
        return Record(envelope: envelope, claims: claims)
    }

    /// Provisional local 14d clock used when first-run register is offline.
    /// Not cryptographic authority — upgraded to a signed token at earliest start when online.
    struct ProvisionalRecord: Codable, Equatable, Sendable {
        let startedAt: Date
        let fingerprint: String

        var endsAt: Date {
            startedAt.addingTimeInterval(TimeInterval(DeviceTrialClock.durationDays) * 86_400)
        }

        func evaluation(at date: Date = .now) -> Evaluation {
            if date < startedAt.addingTimeInterval(-5 * 60) { return .invalid }
            if endsAt <= date { return .expired }
            return .allowed
        }

        func snapshot(at date: Date = .now) -> AppAccessSnapshot? {
            guard evaluation(at: date) == .allowed else { return nil }
            return AppAccessSnapshot(
                license: .trial,
                trialEndsAt: endsAt,
                offlineValidUntil: nil
            )
        }
    }

    static let provisionalKeychainAccount = "voxstudio.app-access.device-trial.provisional"

    static func storeProvisional(
        startedAt: Date,
        fingerprint: String,
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: DeviceTrialClock.provisionalKeychainAccount)
        }
    ) throws -> ProvisionalRecord {
        let record = ProvisionalRecord(startedAt: startedAt, fingerprint: fingerprint)
        let data = try JSONEncoder().encode(record)
        try write(data.base64EncodedString())
        return record
    }

    static func loadProvisional(
        fingerprint: String? = nil,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.provisionalKeychainAccount)
        }
    ) throws -> ProvisionalRecord? {
        guard let value = try read(),
              let data = Data(base64Encoded: value),
              let record = try? JSONDecoder().decode(ProvisionalRecord.self, from: data)
        else { return nil }
        if let fingerprint, record.fingerprint != fingerprint { return nil }
        return record
    }

    static func clearProvisional(
        delete: () throws -> Void = {
            try KeychainStore.deleteThisDeviceOnly(account: DeviceTrialClock.provisionalKeychainAccount)
        }
    ) throws {
        try delete()
    }

    /// Earliest local start hint for register: provisional, else legacy plaintext PR1 clock.
    static func earliestClientStartedAtHint() -> Date? {
        if let provisional = try? loadProvisional() {
            return provisional.startedAt
        }
        return legacyStartedAtHint()
    }

    static func activeSnapshot(
        at date: Date = .now,
        fingerprint: String? = nil,
        publicKeyRaw: Data = DeviceTrialLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> AppAccessSnapshot? {
        if let record = try load(fingerprint: fingerprint, publicKeyRaw: publicKeyRaw, read: read) {
            // Signed token present: never fall back to provisional (expired must stay blocked).
            guard record.evaluation(at: date) == .allowed,
                  let snapshot = record.snapshot(at: date),
                  snapshot.policy(at: date) == .allowed else { return nil }
            return snapshot
        }
        // No signed token yet — provisional local 14d until online register upgrades it.
        if let provisional = try loadProvisional(fingerprint: fingerprint),
           let snapshot = provisional.snapshot(at: date),
           snapshot.policy(at: date) == .allowed {
            return snapshot
        }
        return nil
    }

    static func currentSnapshot(
        at date: Date = .now,
        fingerprint: String? = nil,
        publicKeyRaw: Data = DeviceTrialLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
        }
    ) throws -> AppAccessSnapshot? {
        if let snapshot = try load(fingerprint: fingerprint, publicKeyRaw: publicKeyRaw, read: read)?.snapshot(at: date) {
            return snapshot
        }
        return try loadProvisional(fingerprint: fingerprint)?.snapshot(at: date)
    }

    private struct LegacyRecord: Codable {
        let startedAt: Date
    }
}
