import Foundation

/// Device-local 14-day trial clock (PR1.1).
/// Keychain stores a signed Ed25519 JWT as the authority (not plaintext startedAt).
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
        func isChronologicallyValid(at date: Date) -> Bool {
            date >= claims.startedAt && date >= claims.issuedAt
        }

        func graceEndsAt(at date: Date = .now) -> Date {
            min(claims.endsAt, envelope.lastVerifiedAt.addingTimeInterval(DeviceTrialClock.offlineGrace))
        }

        func evaluation(at date: Date = .now) -> Evaluation {
            guard isChronologicallyValid(at: date) else { return .invalid }
            if claims.endsAt <= date { return .expired }
            if graceEndsAt(at: date) <= date { return .verificationRequired }
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
            let claims = try DeviceTrialLicense.verify(
                envelope.token,
                fingerprint: fingerprint ?? envelope.fingerprint,
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
        return Record(envelope: envelope, claims: claims)
    }

    static func activeSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        guard let record = try load(),
              record.evaluation(at: date) == .allowed,
              let snapshot = record.snapshot(at: date),
              snapshot.policy(at: date) == .allowed else { return nil }
        return snapshot
    }

    static func currentSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        try load()?.snapshot(at: date)
    }

    private struct LegacyRecord: Codable {
        let startedAt: Date
    }
}
