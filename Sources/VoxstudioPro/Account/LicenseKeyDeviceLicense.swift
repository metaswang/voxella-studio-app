import CryptoKit
import Foundation

enum LicenseKeyDeviceLicenseError: Error {
    case malformed
    case invalidSignature
    case invalidType
    case fingerprintMismatch
    case leaseExpired
}

enum LicenseKeyDeviceLicense {
    /// Same Ed25519 public key as device-trial (MAC_ACCESS_DEVICE_TRIAL_PRIVATE_KEY).
    static let publicKeyRaw = DeviceTrialLicense.publicKeyRaw

    struct Claims: Equatable, Sendable {
        let licenseKeyID: UUID
        let fingerprint: String
        let userID: UUID?
        let issuedAt: Date
        let expiresAt: Date
        let jti: String
    }

    static func verify(
        _ token: String,
        fingerprint: String? = nil,
        publicKeyRaw: Data = publicKeyRaw,
        now: Date = .now,
        requireUnexpired: Bool = false
    ) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LicenseKeyDeviceLicenseError.malformed }
        let headerData = try DeviceTrialLicense.base64URLDecode(String(parts[0]))
        let payloadData = try DeviceTrialLicense.base64URLDecode(String(parts[1]))
        let signature = try DeviceTrialLicense.base64URLDecode(String(parts[2]))
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "EdDSA"
        else {
            throw LicenseKeyDeviceLicenseError.malformed
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw LicenseKeyDeviceLicenseError.invalidSignature
        }
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["typ"] as? String == "license_key_device",
              let fp = payload["fp"] as? String,
              let lkidRaw = payload["lkid"] as? String,
              let lkid = UUID(uuidString: lkidRaw)
        else {
            throw LicenseKeyDeviceLicenseError.invalidType
        }
        if let fingerprint, fingerprint != fp {
            throw LicenseKeyDeviceLicenseError.fingerprintMismatch
        }
        var userID: UUID?
        if let uidRaw = payload["uid"] as? String {
            userID = UUID(uuidString: uidRaw)
        }
        let issuedAt = try date(payload["iat"])
        let expiresAt = try date(payload["exp"])
        if requireUnexpired, now >= expiresAt {
            throw LicenseKeyDeviceLicenseError.leaseExpired
        }
        return Claims(
            licenseKeyID: lkid,
            fingerprint: fp,
            userID: userID,
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
        throw LicenseKeyDeviceLicenseError.malformed
    }
}
