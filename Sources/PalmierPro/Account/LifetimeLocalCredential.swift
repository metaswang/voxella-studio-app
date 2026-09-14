import Foundation

/// Lifetime device credential (PR2).
/// Independent ThisDeviceOnly Keychain account — must survive logout / AppAccessCache clear.
/// Authority is a signed Ed25519 JWT bound to user_id + device fingerprint.
enum LifetimeLocalCredential {
    static let keychainAccount = "voxstudio.app-access.lifetime-credential"
    static let verifyInterval: TimeInterval = 24 * 3_600
    static let verifyRetryInterval: TimeInterval = 5 * 60

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

        func isChronologicallyValid(at date: Date) -> Bool {
            date >= claims.issuedAt
        }

        func snapshot(at date: Date = .now) -> AppAccessSnapshot? {
            guard isChronologicallyValid(at: date) else { return nil }
            // Local Lifetime credential unlocks local features without an online lease.
            return AppAccessSnapshot(
                license: .lifetime,
                trialEndsAt: nil,
                offlineValidUntil: nil
            )
        }

        func refreshIsDue(at date: Date = .now, lastAttempt: Date? = nil) -> Bool {
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < LifetimeLocalCredential.verifyRetryInterval {
                return false
            }
            return date.timeIntervalSince(envelope.lastVerifiedAt) >= LifetimeLocalCredential.verifyInterval
        }
    }

    static func load(
        fingerprint: String? = nil,
        userID: UUID? = nil,
        publicKeyRaw: Data = LifetimeDeviceLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount)
        }
    ) throws -> Record? {
        guard let value = try read(),
              let data = Data(base64Encoded: value),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        let claims = try LifetimeDeviceLicense.verify(
            envelope.token,
            fingerprint: fingerprint ?? envelope.fingerprint,
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

    /// True only when a cryptographically verified Lifetime device credential is present.
    static func isPresent(
        fingerprint: String? = nil,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LifetimeLocalCredential.keychainAccount)
        },
        publicKeyRaw: Data = LifetimeDeviceLicense.publicKeyRaw
    ) -> Bool {
        (try? load(fingerprint: fingerprint, publicKeyRaw: publicKeyRaw, read: read)) != nil
    }

    static func activeSnapshot(at date: Date = .now) throws -> AppAccessSnapshot? {
        guard let record = try load(),
              let snapshot = record.snapshot(at: date) else { return nil }
        return snapshot
    }
}
