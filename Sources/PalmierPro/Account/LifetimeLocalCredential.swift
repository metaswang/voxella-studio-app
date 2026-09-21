import Foundation

/// Lifetime device credential (PR2/PR3).
/// Independent ThisDeviceOnly Keychain account — must survive logout / AppAccessCache clear.
/// Authority is a signed Ed25519 JWT bound to user_id + device fingerprint with server-issued lease (exp; default 14d).
enum LifetimeLocalCredential {
    static let keychainAccount = "voxstudio.app-access.lifetime-credential"
    static let verifyInterval: TimeInterval = 24 * 3_600
    static let verifyRetryInterval: TimeInterval = 5 * 60
    static let expiryLead: TimeInterval = 24 * 3_600

    struct Envelope: Codable, Equatable, Sendable {
        let token: String
        let fingerprint: String
        let userID: String
        let lastVerifiedAt: Date
    }

    struct Record: Equatable, Sendable {
        let envelope: Envelope
        let claims: LifetimeDeviceLicense.Claims

        var userID: UUID { claims.userID }
        var fingerprint: String { claims.fingerprint }
        var lastVerifiedAt: Date { envelope.lastVerifiedAt }
        var expiresAt: Date { claims.expiresAt }
        var token: String { envelope.token }

        /// Allows ~5 min skew on iat so client clock behind server does not invalidate.
        func isChronologicallyValid(at date: Date) -> Bool {
            let iatSkewTolerance: TimeInterval = 5 * 60
            return date >= claims.issuedAt.addingTimeInterval(-iatSkewTolerance) && date < claims.expiresAt
        }

        func snapshot(at date: Date = .now) -> AppAccessSnapshot? {
            guard isChronologicallyValid(at: date) else { return nil }
            return AppAccessSnapshot(
                license: .lifetime,
                trialEndsAt: nil,
                offlineValidUntil: claims.expiresAt
            )
        }

        func refreshIsDue(at date: Date = .now, lastAttempt: Date? = nil) -> Bool {
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < LifetimeLocalCredential.verifyRetryInterval {
                return false
            }
            if date.addingTimeInterval(LifetimeLocalCredential.expiryLead) >= claims.expiresAt {
                return true
            }
            return date.timeIntervalSince(envelope.lastVerifiedAt) >= LifetimeLocalCredential.verifyInterval
        }
    }

    static func load(
        fingerprint: String? = nil,
        userID: UUID? = nil,
        publicKeyRaw: Data = LifetimeDeviceLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount).get()
        }
    ) throws -> Record? {
        guard let value = try read(),
              let data = Data(base64Encoded: value),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        let liveFingerprint = fingerprint ?? (try? DeviceFingerprint.current()) ?? envelope.fingerprint
        let claims = try LifetimeDeviceLicense.verify(
            envelope.token,
            fingerprint: liveFingerprint,
            userID: userID,
            publicKeyRaw: publicKeyRaw
        )
        return Record(envelope: envelope, claims: claims)
    }

    static func store(
        token: String,
        fingerprint: String,
        userID: UUID,
        verifiedAt: Date = .now,
        publicKeyRaw: Data = LifetimeDeviceLicense.publicKeyRaw,
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: LifetimeLocalCredential.keychainAccount)
        }
    ) throws -> Record {
        let claims = try LifetimeDeviceLicense.verify(
            token,
            fingerprint: fingerprint,
            userID: userID,
            publicKeyRaw: publicKeyRaw
        )
        let envelope = Envelope(
            token: token,
            fingerprint: fingerprint,
            userID: userID.uuidString,
            lastVerifiedAt: verifiedAt
        )
        let data = try JSONEncoder().encode(envelope)
        try write(data.base64EncodedString())
        return Record(envelope: envelope, claims: claims)
    }

    /// True only when a cryptographically verified, unexpired Lifetime device credential is present.
    static func isPresent(
        fingerprint: String? = nil,
        at date: Date = .now,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount).get()
        },
        publicKeyRaw: Data = LifetimeDeviceLicense.publicKeyRaw
    ) -> Bool {
        let liveFingerprint = fingerprint ?? (try? DeviceFingerprint.current())
        guard let record = try? load(fingerprint: liveFingerprint, publicKeyRaw: publicKeyRaw, read: read) else {
            return false
        }
        return record.isChronologicallyValid(at: date)
    }

    static func clear(
        delete: () throws -> Void = {
            try KeychainStore.deleteThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount)
        }
    ) throws {
        try delete()
    }

    static func activeSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        guard let record = try load(),
              let snapshot = record.snapshot(at: date) else { return nil }
        return snapshot
    }
}
