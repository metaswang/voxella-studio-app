import Foundation
import Security

#if !MAC_APP_STORE
enum AnonymousLifetimePhase: Equatable {
    case idle
    case awaitingPayment
    case waitingForConfirmation
    case unlocked(recoveryCode: String)
    case needsActivation(recoveryCode: String)
    case failed(String)
}

/// Pending DMG Lifetime checkout. Separate ThisDeviceOnly item so sign-out does not drop it.
enum AnonymousLifetimeCheckoutStore {
    static let keychainAccount = "voxstudio.app-access.anonymous-lifetime-checkout"

    struct Pending: Codable, Equatable, Sendable {
        var idempotencyKey: String
        var claimCredential: String
        var fingerprint: String
        var checkoutID: UUID?
        var checkoutURL: String?
        var expiresAt: Date?
        var recoveryCode: String?
        var fulfilled: Bool
    }

    static func load(
        read: () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: AnonymousLifetimeCheckoutStore.keychainAccount).get()
        }
    ) -> Pending? {
        guard let value = try? read(),
              let data = Data(base64Encoded: value),
              let pending = try? JSONDecoder().decode(Pending.self, from: data)
        else { return nil }
        return pending
    }

    static func save(
        _ pending: Pending,
        write: (String) throws -> Void = {
            try KeychainStore.saveThisDeviceOnly($0, account: AnonymousLifetimeCheckoutStore.keychainAccount)
        }
    ) throws {
        let data = try JSONEncoder().encode(pending)
        try write(data.base64EncodedString())
    }

    static func clear(
        delete: () throws -> Void = {
            try KeychainStore.deleteThisDeviceOnly(account: AnonymousLifetimeCheckoutStore.keychainAccount)
        }
    ) {
        try? delete()
    }

    static func makeClaimCredential() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
