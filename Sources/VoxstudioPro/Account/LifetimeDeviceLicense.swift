import CryptoKit
import Foundation

enum LifetimeDeviceLicenseError: Error {
    case malformed
    case invalidSignature
    case invalidType
    case fingerprintMismatch
    case userMismatch
    case leaseExpired
}

enum LifetimeDeviceLicense {
    /// Same Ed25519 public key as device-trial (MAC_ACCESS_DEVICE_TRIAL_PRIVATE_KEY).
    /// RELEASE CHECKLIST: Verify this key matches the server's private key before shipping.
    static let publicKeyRaw = DeviceTrialLicense.publicKeyRaw
    /// Fallback when a legacy PR2 token omits `exp`. Prefer server-provided `exp` / `lease_ends_at`.
    /// Matches API default MAC_ACCESS_LIFETIME_LEASE_DAYS (14).
    static let leaseDays = 14

    struct Claims: Equatable, Sendable {
        let userID: UUID
        let fingerprint: String
        let issuedAt: Date
        let expiresAt: Date
        let jti: String
    }

    static func verify(
        _ token: String,
        fingerprint: String? = nil,
        userID: UUID? = nil,
        publicKeyRaw: Data = publicKeyRaw,
        now: Date = .now,
        requireUnexpired: Bool = false
    ) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LifetimeDeviceLicenseError.malformed }
        let headerData = try DeviceTrialLicense.base64URLDecode(String(parts[0]))
        let payloadData = try DeviceTrialLicense.base64URLDecode(String(parts[1]))
        let signature = try DeviceTrialLicense.base64URLDecode(String(parts[2]))
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "EdDSA"
        else {
            throw LifetimeDeviceLicenseError.malformed
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw LifetimeDeviceLicenseError.invalidSignature
        }
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["typ"] as? String == "lifetime_device",
              let fp = payload["fp"] as? String,
              let uidRaw = payload["uid"] as? String,
              let uid = UUID(uuidString: uidRaw)
        else {
            throw LifetimeDeviceLicenseError.invalidType
        }
        if let fingerprint, fingerprint != fp {
            throw LifetimeDeviceLicenseError.fingerprintMismatch
        }
        if let userID, userID != uid {
            throw LifetimeDeviceLicenseError.userMismatch
        }
        let issuedAt = try date(payload["iat"])
        // Legacy PR2 tokens omit exp; treat as issuedAt + leaseDays (14d default).
        // Prefer force-renew before hard deny when transitioning 30d → 14d defaults.
        let expiresAt: Date
        if payload["exp"] != nil {
            expiresAt = try date(payload["exp"])
        } else {
            expiresAt = issuedAt.addingTimeInterval(TimeInterval(leaseDays * 24 * 3_600))
        }
        if requireUnexpired, now >= expiresAt {
            throw LifetimeDeviceLicenseError.leaseExpired
        }
        return Claims(
            userID: uid,
            fingerprint: fp,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            jti: payload["jti"] as? String ?? ""
        )
    }

    private static func date(_ value: Any?) throws -> Date {
        if let value = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = value as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        throw LifetimeDeviceLicenseError.malformed
    }
}
