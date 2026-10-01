import CryptoKit
import Foundation
import IOKit

enum DeviceFingerprintError: Error {
    case unavailable
}

enum DeviceFingerprint {
    /// Compile-time pepper. Only the HMAC is uploaded; IOPlatformUUID never leaves the device.
    static let pepper = "voxstudio.device-trial.pepper.v1"

    static func current(uuid: () throws -> String = platformUUID) throws -> String {
        try hash(uuid: uuid(), pepper: pepper)
    }

    static func hash(uuid: String, pepper: String = pepper) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(uuid.utf8),
            using: SymmetricKey(data: Data(pepper.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func platformUUID() throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { throw DeviceFingerprintError.unavailable }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            throw DeviceFingerprintError.unavailable
        }
        let value = cf.takeRetainedValue()
        guard let uuid = value as? String,
              !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DeviceFingerprintError.unavailable
        }
        return uuid
    }
}
