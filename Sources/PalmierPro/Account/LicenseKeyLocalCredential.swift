import Foundation

/// License-key device credential.
/// Independent ThisDeviceOnly Keychain account — must survive logout / AppAccessCache clear.
/// Authority is a signed Ed25519 JWT bound to license_key_id + device fingerprint (login optional).
enum LicenseKeyLocalCredential {
    static let keychainAccount = "voxstudio.app-access.license-key-credential"
    static let verifyInterval: TimeInterval = 24 * 3_600
    static let verifyRetryInterval: TimeInterval = 5 * 60
    static let expiryLead: TimeInterval = 24 * 3_600

    struct Envelope: Codable, Equatable, Sendable {
        let token: String
        let fingerprint: String
        let licenseKeyID: String
        let userID: String?
        let lastVerifiedAt: Date
    }

    struct Record: Equatable, Sendable {
        let envelope: Envelope
        let claims: LicenseKeyDeviceLicense.Claims

        var licenseKeyID: UUID { claims.licenseKeyID }
        var fingerprint: String { claims.fingerprint }
        var userID: UUID? { claims.userID }
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
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < LicenseKeyLocalCredential.verifyRetryInterval {
                return false
            }
            if date.addingTimeInterval(LicenseKeyLocalCredential.expiryLead) >= claims.expiresAt {
                return true
            }
            return date.timeIntervalSince(envelope.lastVerifiedAt) >= LicenseKeyLocalCredential.verifyInterval
        }
    }

    static func load(
        fingerprint: String? = nil,
        publicKeyRaw: Data = LicenseKeyDeviceLicense.publicKeyRaw,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LicenseKeyLocalCredential.keychainAccount)
        }
    ) throws -> Record? {
        guard let value = try read(),
              let data = Data(base64Encoded: value),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        let liveFingerprint = fingerprint ?? (try? DeviceFingerprint.current()) ?? envelope.fingerprint
        let claims = try LicenseKeyDeviceLicense.verify(
            envelope.token,
            fingerprint: liveFingerprint,
            publicKeyRaw: publicKeyRaw
        )
        return Record(envelope: envelope, claims: claims)
    }

    static func store(
        token: String,
        fingerprint: String,
        verifiedAt: Date = .now,
        publicKeyRaw: Data = LicenseKeyDeviceLicense.publicKeyRaw,
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: LicenseKeyLocalCredential.keychainAccount)
        }
    ) throws -> Record {
        let claims = try LicenseKeyDeviceLicense.verify(
            token,
            fingerprint: fingerprint,
            publicKeyRaw: publicKeyRaw
        )
        let envelope = Envelope(
            token: token,
            fingerprint: fingerprint,
            licenseKeyID: claims.licenseKeyID.uuidString,
            userID: claims.userID?.uuidString,
            lastVerifiedAt: verifiedAt
        )
        let data = try JSONEncoder().encode(envelope)
        try write(data.base64EncodedString())
        return Record(envelope: envelope, claims: claims)
    }

    /// True only when a cryptographically verified, unexpired license-key device credential is present.
    static func isPresent(
        fingerprint: String? = nil,
        at date: Date = .now,
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: LicenseKeyLocalCredential.keychainAccount)
        },
        publicKeyRaw: Data = LicenseKeyDeviceLicense.publicKeyRaw
    ) -> Bool {
        let liveFingerprint = fingerprint ?? (try? DeviceFingerprint.current())
        guard let record = try? load(fingerprint: liveFingerprint, publicKeyRaw: publicKeyRaw, read: read) else {
            return false
        }
        return record.isChronologicallyValid(at: date)
    }

    static func clear(
        delete: () throws -> Void = {
            try KeychainStore.deleteThisDeviceOnly(account: LicenseKeyLocalCredential.keychainAccount)
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
