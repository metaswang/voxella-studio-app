import CryptoKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("App access")
struct AppAccessTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func activeTrialCanCreateButCannotBuyCredits() throws {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(1),
            offlineValidUntil: now.addingTimeInterval(1)
        )

        #expect(access.policy(at: now) == .allowed)
        #expect(!access.canPurchaseCredits)
        try access.policy(at: now).requireNewContent()
    }

    @Test func expiredTrialBlocksNewContent() {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now,
            offlineValidUntil: now
        )

        #expect(access.policy(at: now) == .expired)
        #expect(throws: AppAccessError.trialExpired) {
            try access.policy(at: now).requireNewContent()
        }
    }

    @Test func lifetimeKeepsCreationAndTopUpsAfterSubscriptionExpires() {
        let access = AppAccessSnapshot(
            license: .lifetime,
            subscriptionTier: AccountTier(rawValue: "pro"),
            subscriptionEndsAt: now,
            offlineValidUntil: now.addingTimeInterval(86400)
        )

        #expect(access.policy(at: now) == .allowed)
        #expect(access.canPurchaseCredits(at: now))
    }

    @Test func activeStarterSubscriptionCanCreateAndBuyCredits() {
        let access = AppAccessSnapshot(
            subscriptionTier: AccountTier(rawValue: "starter"),
            subscriptionEndsAt: now.addingTimeInterval(1),
            offlineValidUntil: now.addingTimeInterval(1)
        )

        #expect(access.policy(at: now) == .allowed)
        #expect(access.canPurchaseCredits(at: now))
    }

    @Test func expiredSubscriptionCannotBuyCredits() {
        let access = AppAccessSnapshot(subscriptionTier: AccountTier(rawValue: "pro"), subscriptionEndsAt: now)
        #expect(!access.canPurchaseCredits(at: now))
    }

    @Test func lifetimeOfflineLeaseExpiresAtBoundary() {
        let access = AppAccessSnapshot(license: .lifetime, offlineValidUntil: now)
        #expect(access.policy(at: now.addingTimeInterval(-1)) == .allowed)
        #expect(access.policy(at: now) == .verificationRequired)
    }

    @Test func serverFractionalDatesAndPromotionDecode() throws {
        let data = Data(#"{"license":"trial","trial_ends_at":"2027-09-10T16:00:00.123456+00:00","subscription_source":"app_store","lifetime_promotion":{"credits":500,"ends_at":"2027-09-10T16:00:00+00:00"}}"#.utf8)
        let response = try JSONDecoder().decode(AppAccessResponse.self, from: data)
        #expect(response.trialEndsAt != nil)
        #expect(response.subscriptionSource == .appStore)
        #expect(response.lifetimePromotion?.credits == 500)
    }

    @Test func signedOutUserCanCreateDuringActiveTrial() throws {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86400),
            offlineValidUntil: now.addingTimeInterval(86400)
        )
        #expect(AppAccessGate.canCreateNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            hasLocalLifetimeCredential: false,
            at: now
        ))
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            hasLocalLifetimeCredential: false,
            at: now
        )
    }

    @Test func signedOutUserWithLocalLifetimeCredentialCanCreate() throws {
        let access = AppAccessSnapshot()
        #expect(AppAccessGate.canCreateNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            hasLocalLifetimeCredential: true,
            at: now
        ))
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            hasLocalLifetimeCredential: true,
            at: now
        )
    }

    @Test func paidSubscriptionStillRequiresSignIn() {
        let access = AppAccessSnapshot(
            subscriptionTier: AccountTier(rawValue: "pro"),
            subscriptionEndsAt: now.addingTimeInterval(86400),
            offlineValidUntil: now.addingTimeInterval(86400)
        )
        #expect(!AppAccessGate.canCreateNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            hasLocalLifetimeCredential: false,
            at: now
        ))
        #expect(throws: AppAccessError.signInRequired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: access,
                hasLocalLifetimeCredential: false,
                at: now
            )
        }
        #expect(AppAccessGate.canCreateNewContent(
            enforced: true,
            signedIn: true,
            access: access,
            hasLocalLifetimeCredential: false,
            at: now
        ))
    }

    @Test func expiredTrialBlocksEvenWhenSignedOut() {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now,
            offlineValidUntil: now
        )
        #expect(throws: AppAccessError.trialExpired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: access,
                hasLocalLifetimeCredential: false,
                at: now
            )
        }
    }

    @Test func deviceTrialAllowsWithoutOfflineLease() {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86400)
        )
        #expect(access.policy(at: now) == .allowed)
        #expect(access.hasLocalFeatureEntitlement(at: now))
    }

    @Test func unpaidAccountNeverDisplaysLifetime() {
        let access = AppAccessSnapshot()
        #expect(AppAccessGate.label(enforced: true, access: access, tier: .none) == "Free")
        #expect(AppAccessGate.label(enforced: false, access: access, tier: .none) == "Free")
    }

    @Test func subscriptionOfflineLeaseDoesNotExtendPaidPeriod() {
        let access = AppAccessSnapshot(subscriptionTier: AccountTier(rawValue: "pro"),
                                       subscriptionEndsAt: now,
                                       offlineValidUntil: now.addingTimeInterval(86400))
        #expect(access.policy(at: now) == .expired)
    }

    @Test func subscriptionRequiresRefreshAfterOfflineLeaseEnds() {
        let access = AppAccessSnapshot(subscriptionTier: AccountTier(rawValue: "pro"),
                                       subscriptionEndsAt: now.addingTimeInterval(86400),
                                       offlineValidUntil: now)
        #expect(access.policy(at: now.addingTimeInterval(-1)) == .allowed)
        #expect(access.policy(at: now) == .verificationRequired)
    }

    @Test func onlyRealLifetimeEntitlementDisplaysLifetime() {
        let access = AppAccessSnapshot(license: .lifetime)
        #expect(AppAccessGate.label(enforced: true, access: access, tier: .none) == "Lifetime")
        #expect(AppAccessGate.label(enforced: false, access: access, tier: .none) == "Free")
    }

    @Test func fingerprintHashesUUIDAndDoesNotEqualRawUUID() {
        let uuid = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        let fingerprint = DeviceFingerprint.hash(uuid: uuid)
        #expect(fingerprint.count == 64)
        #expect(fingerprint != uuid)
        #expect(fingerprint == DeviceFingerprint.hash(uuid: uuid))
        #expect(fingerprint != DeviceFingerprint.hash(uuid: uuid, pepper: "other"))
    }

    @Test func signedDeviceTrialIsAuthorityAndSurvivesReload() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-a")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        let record = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(record.startedAt == Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.towardZero)))
        #expect(record.endsAt == Date(timeIntervalSince1970: ends.timeIntervalSince1970.rounded(.towardZero)))

        let loaded = try DeviceTrialClock.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(loaded?.endsAt == record.endsAt)
        #expect(loaded?.snapshot(at: now)?.policy(at: now) == .allowed)
    }

    @Test func wipeKeychainReregisterKeepsSameEndsAt() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-b")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        let first = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        stored = nil
        let again = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now.addingTimeInterval(3600),
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(again.endsAt == first.endsAt)
    }

    @Test func tamperedDeviceTrialTokenFailsVerify() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-c")
        let token = try keys.token(
            fingerprint: fingerprint,
            startedAt: now,
            endsAt: now.addingTimeInterval(14 * 86_400),
            issuedAt: now
        )
        let parts = token.split(separator: ".")
        let tampered = "\(parts[0]).\(parts[1].dropLast(2))ab.\(parts[2])"
        #expect(throws: DeviceTrialLicenseError.self) {
            try DeviceTrialLicense.verify(tampered, fingerprint: fingerprint, publicKeyRaw: keys.publicKeyRaw)
        }
    }

    @Test func deviceTrialRejectsClockRollback() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-d")
        let token = try keys.token(
            fingerprint: fingerprint,
            startedAt: now,
            endsAt: now.addingTimeInterval(14 * 86_400),
            issuedAt: now
        )
        var stored: String?
        _ = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        let snapshot = try DeviceTrialClock.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )?.snapshot(at: now.addingTimeInterval(-1))
        #expect(snapshot == nil)
    }

    @Test func offlineGraceRequiresVerificationWithoutReopeningTrial() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-e")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        let record = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        let overdue = now.addingTimeInterval(DeviceTrialClock.offlineGrace + 1)
        #expect(record.evaluation(at: overdue) == .verificationRequired)
        let snapshot = record.snapshot(at: overdue)
        #expect(snapshot?.policy(at: overdue) == .verificationRequired)
        #expect(throws: AppAccessError.verificationRequired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: snapshot ?? .init(),
                hasLocalLifetimeCredential: false,
                at: overdue
            )
        }
        #expect(record.endsAt == ends.roundedToUnix)
    }

    @Test func deviceTrialVerifyIsDueOnlyAfter24hOrNearExpiry() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "device-f")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        let record = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(!record.refreshIsDue(at: now.addingTimeInterval(23 * 3_600)))
        #expect(record.refreshIsDue(at: now.addingTimeInterval(24 * 3_600)))
        #expect(record.refreshIsDue(at: ends.addingTimeInterval(-23 * 3_600)))
        #expect(!record.refreshIsDue(
            at: now.addingTimeInterval(24 * 3_600),
            lastAttempt: now.addingTimeInterval(24 * 3_600 - 60)
        ))
    }

    @Test func lifetimeLocalCredentialRejectsUnverifiedBlobs() {
        #expect(LifetimeLocalCredential.isPresent(read: { nil }) == false)
        #expect(LifetimeLocalCredential.isPresent(read: { "cred" }) == false)
        #expect(LifetimeLocalCredential.isPresent(read: { "" }) == false)
        #expect(LifetimeLocalCredential.isPresent(read: { "eyJhbGciOiJFZERTQSJ9.fake.sig" }) == false)
    }

    @Test func signedLifetimeDeviceCredentialIsPresentAndSurvivesReload() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "lifetime-device-a")
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: now)
        var stored: String?
        let record = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(record.userID == userID)
        #expect(LifetimeLocalCredential.isPresent(
            fingerprint: fingerprint,
            read: { stored },
            publicKeyRaw: keys.publicKeyRaw
        ))
        let loaded = try LifetimeLocalCredential.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(loaded?.userID == userID)
        #expect(loaded?.snapshot(at: now)?.license == .lifetime)
        #expect(loaded?.snapshot(at: now)?.policy(at: now) == .allowed)
    }

    @Test func lifetimeDeviceCredentialBindsUserAndFingerprint() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "lifetime-device-b")
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: now)
        #expect(throws: LifetimeDeviceLicenseError.self) {
            try LifetimeDeviceLicense.verify(
                token,
                fingerprint: DeviceFingerprint.hash(uuid: "other"),
                publicKeyRaw: keys.publicKeyRaw
            )
        }
        #expect(throws: LifetimeDeviceLicenseError.self) {
            try LifetimeDeviceLicense.verify(
                token,
                fingerprint: fingerprint,
                userID: UUID(),
                publicKeyRaw: keys.publicKeyRaw
            )
        }
    }

    @Test func lifetimeLocalCredentialAllowsGateWithoutLogin() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "lifetime-device-c")
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: now)
        var stored: String?
        _ = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        let present = LifetimeLocalCredential.isPresent(
            fingerprint: fingerprint,
            read: { stored },
            publicKeyRaw: keys.publicKeyRaw
        )
        #expect(present)
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: .init(),
            hasLocalLifetimeCredential: present,
            at: now
        )
    }
}

private struct LifetimeDeviceTestKeys {
    let privateKey = Curve25519.Signing.PrivateKey()
    var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

    func token(userID: UUID, fingerprint: String, issuedAt: Date) throws -> String {
        let header = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT", "kid": "lifetime-device-v1"])
        )
        let payload = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: [
                "typ": "lifetime_device",
                "uid": userID.uuidString,
                "fp": fingerprint,
                "iat": Int(issuedAt.timeIntervalSince1970),
                "jti": "lifetime-test-jti",
            ])
        )
        let input = Data((header + "." + payload).utf8)
        let signature = try privateKey.signature(for: input)
        return header + "." + payload + "." + DeviceTrialLicense.base64URLEncode(signature)
    }
}


private struct DeviceTrialTestKeys {
    let privateKey = Curve25519.Signing.PrivateKey()
    var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

    func token(fingerprint: String, startedAt: Date, endsAt: Date, issuedAt: Date) throws -> String {
        let header = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT", "kid": "device-trial-v1"])
        )
        let payload = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: [
                "typ": "device_trial",
                "fp": fingerprint,
                "started_at": Int(startedAt.timeIntervalSince1970),
                "ends_at": Int(endsAt.timeIntervalSince1970),
                "iat": Int(issuedAt.timeIntervalSince1970),
                "jti": "test-jti",
            ])
        )
        let signingInput = Data("\(header).\(payload)".utf8)
        let signature = try privateKey.signature(for: signingInput)
        return "\(header).\(payload).\(DeviceTrialLicense.base64URLEncode(signature))"
    }
}

private extension Date {
    var roundedToUnix: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.towardZero)) }
}
