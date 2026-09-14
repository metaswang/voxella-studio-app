import CryptoKit
import Foundation

enum DeviceTrialLicenseError: Error {
    case malformed
    case invalidSignature
    case invalidType
    case fingerprintMismatch
}

enum DeviceTrialLicense {
    /// Raw 32-byte Ed25519 public key (base64). Matches API MAC_ACCESS_DEVICE_TRIAL_PRIVATE_KEY v1.
    static let publicKeyRaw = Data(base64Encoded: "OvARTwsbVp9+TDACZeBcUoSvv2KU8gd/LTl3Jy0i1h4=") ?? Data()

    struct Claims: Equatable, Sendable {
        let fingerprint: String
        let startedAt: Date
        let endsAt: Date
        let issuedAt: Date
        let jti: String
    }

    static func verify(
        _ token: String,
        fingerprint: String? = nil,
        publicKeyRaw: Data = publicKeyRaw
    ) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw DeviceTrialLicenseError.malformed }
        let headerData = try base64URLDecode(String(parts[0]))
        let payloadData = try base64URLDecode(String(parts[1]))
        let signature = try base64URLDecode(String(parts[2]))
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "EdDSA"
        else {
            throw DeviceTrialLicenseError.malformed
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw DeviceTrialLicenseError.invalidSignature
        }
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["typ"] as? String == "device_trial",
              let fp = payload["fp"] as? String
        else {
            throw DeviceTrialLicenseError.invalidType
        }
        if let fingerprint, fingerprint != fp {
            throw DeviceTrialLicenseError.fingerprintMismatch
        }
        return Claims(
            fingerprint: fp,
            startedAt: try date(payload["started_at"]),
            endsAt: try date(payload["ends_at"]),
            issuedAt: try date(payload["iat"]),
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
        throw DeviceTrialLicenseError.malformed
    }

    static func base64URLDecode(_ value: String) throws -> Data {
        var encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = encoded.count % 4
        if pad > 0 { encoded.append(String(repeating: "=", count: 4 - pad)) }
        guard let data = Data(base64Encoded: encoded) else {
            throw DeviceTrialLicenseError.malformed
        }
        return data
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
