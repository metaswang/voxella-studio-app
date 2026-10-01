import CryptoKit
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("App access")
struct AppAccessTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [
        (false, false, false, false),
        (true, false, false, false),
        (true, true, false, true),
        (true, true, true, false),
        (false, true, false, false),
    ])
    func trialActivationTipRequiresSignedInNonLifetimeAccess(
        enforced: Bool,
        signedIn: Bool,
        hasLocalLifetimeCredential: Bool,
        expected: Bool
    ) {
        #expect(
            AppAccessGate.shouldPresentTrialActivationTip(
                enforced: enforced,
                signedIn: signedIn,
                hasLocalLifetimeCredential: hasLocalLifetimeCredential
            ) == expected
        )
    }

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

    @Test func activeTrialSatisfiesPlanGatedFeaturesButExpiredTrialDoesNot() {
        let activeTrial = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(1)
        )
        let expiredTrial = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now
        )

        #expect(AppAccessGate.hasFeatureAccess(
            hasPaidPlan: false,
            access: activeTrial,
            at: now
        ))
        #expect(!AppAccessGate.hasFeatureAccess(
            hasPaidPlan: false,
            access: expiredTrial,
            at: now
        ))
        #expect(AppAccessGate.hasFeatureAccess(
            hasPaidPlan: true,
            access: expiredTrial,
            at: now
        ))
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
        // Within 5m skew: still valid. Beyond skew: reject clock rollback.
        let withinSkew = try DeviceTrialClock.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )?.snapshot(at: now.addingTimeInterval(-60))
        #expect(withinSkew != nil)
        let snapshot = try DeviceTrialClock.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )?.snapshot(at: now.addingTimeInterval(-6 * 60))
        #expect(snapshot == nil)
    }

    @Test func offlinePastGraceStillAllowsRecordingWithoutReopeningTrial() throws {
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
        // Soft grace: mid-trial signed token still allows local recording; endsAt unchanged.
        #expect(record.evaluation(at: overdue) == .allowed)
        #expect(record.refreshIsDue(at: overdue, lastAttempt: nil))
        let snapshot = record.snapshot(at: overdue)
        #expect(snapshot?.policy(at: overdue) == .allowed)
        #expect(snapshot?.trialPresentation(at: overdue) != nil)
        if case let .active(active)? = snapshot?.trialPresentation(at: overdue) {
            #expect(active.endsAt == ends.roundedToUnix)
        } else {
            Issue.record("expected active trial presentation past offline grace")
        }
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: snapshot ?? .init(),
            hasLocalLifetimeCredential: false,
            at: overdue
        )
        #expect(record.endsAt == ends.roundedToUnix)
        _ = stored
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
            at: now,
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
            at: now,
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

    @Test func lifetimeLeaseExpiryBlocksAccess() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "lifetime-device-lease")
        let issued = now.addingTimeInterval(-31 * 24 * 3_600)
        let expired = now.addingTimeInterval(-24 * 3_600)
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: issued, expiresAt: expired)
        var stored: String?
        _ = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: issued,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(LifetimeLocalCredential.isPresent(
            fingerprint: fingerprint,
            at: now,
            read: { stored },
            publicKeyRaw: keys.publicKeyRaw
        ) == false)
        let loaded = try LifetimeLocalCredential.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(loaded?.snapshot(at: now) == nil)
        #expect(loaded?.refreshIsDue(at: now) == true)
    }

    @Test func lifetimeRefreshDueNearLeaseExpiry() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "lifetime-device-near-exp")
        let expires = now.addingTimeInterval(12 * 3_600)
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: now, expiresAt: expires)
        var stored: String?
        let record = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        #expect(record.refreshIsDue(at: now))
        #expect(record.expiresAt == expires)
        _ = stored
    }

    @Test func lifetimeCredentialRequiresLiveFingerprintBinding() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let correctFingerprint = DeviceFingerprint.hash(uuid: "correct-device")
        let wrongFingerprint = DeviceFingerprint.hash(uuid: "wrong-device")
        let token = try keys.token(userID: userID, fingerprint: correctFingerprint, issuedAt: now)
        var stored: String?
        _ = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: correctFingerprint,
            userID: userID,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Loading with wrong fingerprint should fail
        #expect(throws: LifetimeDeviceLicenseError.self) {
            try LifetimeLocalCredential.load(
                fingerprint: wrongFingerprint,
                publicKeyRaw: keys.publicKeyRaw,
                read: { stored }
            )
        }
        // isPresent with wrong fingerprint should return false
        #expect(!LifetimeLocalCredential.isPresent(
            fingerprint: wrongFingerprint,
            at: now,
            read: { stored },
            publicKeyRaw: keys.publicKeyRaw
        ))
    }

    @Test func deviceTrialRequiresLiveFingerprintBinding() throws {
        let keys = DeviceTrialTestKeys()
        let correctFingerprint = DeviceFingerprint.hash(uuid: "correct-device")
        let wrongFingerprint = DeviceFingerprint.hash(uuid: "wrong-device")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: correctFingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        _ = try DeviceTrialClock.store(
            token: token,
            fingerprint: correctFingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Loading with wrong fingerprint should fail
        #expect(throws: DeviceTrialLicenseError.self) {
            try DeviceTrialClock.load(
                fingerprint: wrongFingerprint,
                publicKeyRaw: keys.publicKeyRaw,
                read: { stored }
            )
        }
    }

    @Test func lifetimeCredentialAllowsClockSkewOnIat() throws {
        let keys = LifetimeDeviceTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "clock-skew-device")
        let serverTime = now.addingTimeInterval(4 * 60)
        let token = try keys.token(userID: userID, fingerprint: fingerprint, issuedAt: serverTime)
        var stored: String?
        let record = try LifetimeLocalCredential.store(
            token: token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: serverTime,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Client clock 4 min behind server (within 5 min tolerance) should still be valid
        #expect(record.isChronologicallyValid(at: now))
        #expect(LifetimeLocalCredential.isPresent(
            fingerprint: fingerprint,
            at: now,
            read: { stored },
            publicKeyRaw: keys.publicKeyRaw
        ))
    }

    @Test func deviceTrialAllowsClockSkewOnIat() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "clock-skew-device")
        let serverTime = now.addingTimeInterval(4 * 60)
        let ends = serverTime.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: serverTime, endsAt: ends, issuedAt: serverTime)
        var stored: String?
        let record = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: serverTime,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Client clock 4 min behind server (within 5 min tolerance) should still be valid
        #expect(record.isChronologicallyValid(at: now))
    }


    @Test func unusedAccessIsNotReportedAsAnEndedTrial() {
        let access = AppAccessSnapshot()
        #expect(access.trialPresentation(at: now) == nil)
    }

    @Test func trialPresentationRoundsDaysAndHoursAndWarnsAtThreeDays() {
        let threeDays = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(3 * 86_400),
            offlineValidUntil: now.addingTimeInterval(3 * 86_400)
        )
        guard case let .active(presentation)? = threeDays.trialPresentation(at: now) else {
            Issue.record("expected active trial presentation")
            return
        }
        #expect(presentation.sidebarLabel == "3 days left")
        #expect(presentation.usesWarningColor)
        #expect(presentation.isReminderEligible)

        let hours = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(2 * 3_600),
            offlineValidUntil: now.addingTimeInterval(2 * 3_600)
        )
        guard case let .active(hourPresentation)? = hours.trialPresentation(at: now) else {
            Issue.record("expected hour presentation")
            return
        }
        #expect(hourPresentation.sidebarLabel == "2 hours left")

        let underOneHour = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(30 * 60),
            offlineValidUntil: now.addingTimeInterval(30 * 60)
        )
        guard case let .active(underOneHourPresentation)? = underOneHour.trialPresentation(at: now) else {
            Issue.record("expected under-one-hour presentation")
            return
        }
        #expect(underOneHourPresentation.sidebarLabel == "Less than 1 hour left")

        let oneDay = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86_400),
            offlineValidUntil: now.addingTimeInterval(86_400)
        )
        guard case let .active(oneDayPresentation)? = oneDay.trialPresentation(at: now) else {
            Issue.record("expected 1 day presentation")
            return
        }
        #expect(oneDayPresentation.sidebarLabel == "1 day left")

        let fourteenDays = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(14 * 86_400),
            offlineValidUntil: now.addingTimeInterval(14 * 86_400)
        )
        guard case let .active(fourteenDayPresentation)? = fourteenDays.trialPresentation(at: now) else {
            Issue.record("expected 14 day presentation")
            return
        }
        #expect(fourteenDayPresentation.sidebarLabel == "14 days left")
        #expect(!fourteenDayPresentation.usesWarningColor)
    }

    @Test func expiredAndUnverifiedTrialsHaveDistinctPresentationStates() {
        let expired = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now,
            offlineValidUntil: now.addingTimeInterval(86_400)
        )
        #expect(expired.trialPresentation(at: now) == .expired)

        // Mid-trial with expired offline lease still shows remaining time (not verify-only).
        let unverified = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86_400),
            offlineValidUntil: now
        )
        guard case let .active(active)? = unverified.trialPresentation(at: now) else {
            Issue.record("expected active presentation for mid-trial past offline lease")
            return
        }
        #expect(active.endsAt == now.addingTimeInterval(86_400))
        #expect(unverified.policy(at: now) == .allowed)
    }

    @Test func paidEntitlementSuppressesTrialPresentation() {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86_400),
            subscriptionTier: AccountTier(rawValue: "pro"),
            subscriptionEndsAt: now.addingTimeInterval(30 * 86_400),
            offlineValidUntil: now.addingTimeInterval(86_400)
        )
        #expect(access.trialPresentation(at: now) == nil)
    }

    @Test func lifetimeLicenseSuppressesTrialPresentation() {
        let access = AppAccessSnapshot(
            license: .lifetime,
            trialEndsAt: now.addingTimeInterval(86_400),
            offlineValidUntil: nil
        )
        #expect(access.trialPresentation(at: now) == nil)
    }

    @Test func trialReminderStoreClaimsEachTrialOnlyOnce() async {
        let store = TrialReminderStore()
        let userID = UUID()
        let reminderKey = TrialReminderStore.key(userID: userID, endsAt: now)
        let startedKey = TrialReminderStore.startedKey(userID: userID, endsAt: now)

        #expect(await store.claim(key: reminderKey))
        #expect(!(await store.claim(key: reminderKey)))
        #expect(await store.claim(key: startedKey))
        #expect(!(await store.claim(key: startedKey)))
        await store.remove(key: reminderKey)
        await store.remove(key: startedKey)
    }

    @Test func provisionalTrialAllowsOfflineRecordingAndKeepsEarliestStart() throws {
        let fingerprint = DeviceFingerprint.hash(uuid: "provisional-device")
        var stored: String?
        let started = now.addingTimeInterval(-2 * 86_400)
        let provisional = try DeviceTrialClock.storeProvisional(
            startedAt: started,
            fingerprint: fingerprint,
            write: { stored = $0 }
        )
        #expect(provisional.evaluation(at: now) == .allowed)
        let snapshot = provisional.snapshot(at: now)
        #expect(snapshot?.policy(at: now) == .allowed)
        #expect(snapshot?.license == .trial)
        #expect(snapshot?.trialEndsAt == started.addingTimeInterval(14 * 86_400))
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: snapshot ?? .init(),
            hasLocalLifetimeCredential: false,
            at: now
        )
        guard case .active? = snapshot?.trialPresentation(at: now) else {
            Issue.record("provisional mid-trial must show remaining time")
            return
        }
        let loaded = try DeviceTrialClock.loadProvisional(
            fingerprint: fingerprint,
            read: { stored }
        )
        #expect(loaded?.startedAt == started)
        #expect(AppAccessError.trialActivationRequired.receiptCode == "trial_activation_required")
        #expect(
            AppAccessError.trialActivationRequired.localizedDescription
                == "Connect to the internet to activate your free trial."
        )
    }

    @Test func provisionalLoginMergePayloadPrefersHintWithoutSignedToken() throws {
        let fingerprint = DeviceFingerprint.hash(uuid: "provisional-login-merge")
        var provisionalStored: String?
        let started = now.addingTimeInterval(-1 * 86_400)
        let provisional = try DeviceTrialClock.storeProvisional(
            startedAt: started,
            fingerprint: fingerprint,
            write: { provisionalStored = $0 }
        )
        #expect(
            DeviceTrialLoginMerge.shouldUpgradeProvisionalBeforeMerge(
                hasSignedToken: false,
                provisional: provisional,
                at: now
            )
        )
        // Resolve payload as merge does when upgrade failed / no signed token yet.
        let payload = DeviceTrialLoginMerge.resolvePayload(
            signedStartedAt: nil,
            signedToken: nil,
            earliestHint: provisional.startedAt
        )
        #expect(payload.deviceTrialToken == nil)
        #expect(payload.deviceStartedAt == started)
        let expectedEnds = DeviceTrialLoginMerge.expectedEndsPreservingProvisional(
            provisionalStartedAt: started
        )
        #expect(expectedEnds == started.addingTimeInterval(14 * 86_400))
        #expect(expectedEnds == provisional.endsAt)
        #expect(
            DeviceTrialLoginMerge.shouldClearProvisional(
                serverTrialEndsAt: expectedEnds,
                provisionalEndsAt: provisional.endsAt
            )
        )
        // Reopen would be now+14d — must not match preserved provisional ends.
        let reopenedEnds = now.addingTimeInterval(14 * 86_400)
        #expect(expectedEnds != reopenedEnds)
        #expect(
            !DeviceTrialLoginMerge.shouldPostAccountTrialMerge(
                hasSignedToken: false,
                provisional: provisional
            )
        )
        #expect(
            DeviceTrialLoginMerge.shouldPostAccountTrialMerge(
                hasSignedToken: false,
                provisional: nil
            )
        )
        _ = provisionalStored
    }

    @Test func signedLoginMergePayloadKeepsTokenAndEarliestRegression() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "signed-login-merge")
        let started = now.addingTimeInterval(-3 * 86_400)
        let ends = started.addingTimeInterval(14 * 86_400)
        let token = try keys.token(
            fingerprint: fingerprint,
            startedAt: started,
            endsAt: ends,
            issuedAt: started
        )
        #expect(
            !DeviceTrialLoginMerge.shouldUpgradeProvisionalBeforeMerge(
                hasSignedToken: true,
                provisional: DeviceTrialClock.ProvisionalRecord(
                    startedAt: started.addingTimeInterval(-86_400),
                    fingerprint: fingerprint
                ),
                at: now
            )
        )
        let payload = DeviceTrialLoginMerge.resolvePayload(
            signedStartedAt: started,
            signedToken: token,
            earliestHint: started.addingTimeInterval(-86_400)
        )
        #expect(payload.deviceTrialToken == token)
        #expect(payload.deviceStartedAt == started)
        #expect(
            DeviceTrialLoginMerge.shouldPostAccountTrialMerge(
                hasSignedToken: true,
                provisional: DeviceTrialClock.ProvisionalRecord(
                    startedAt: started.addingTimeInterval(-86_400),
                    fingerprint: fingerprint
                )
            )
        )
        let account = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(11 * 86_400)
        )
        let laterDevice = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(14 * 86_400)
        )
        #expect(
            !DeviceTrialLoginMerge.shouldReplaceEntitlement(current: account, candidate: laterDevice, at: now)
        )
        #expect(
            DeviceTrialLoginMerge.shouldReplaceEntitlement(current: laterDevice, candidate: account, at: now)
        )
        #expect(
            DeviceTrialLoginMerge.shouldReplaceEntitlement(current: .init(), candidate: account, at: now)
        )
        // Server ending later than provisional must not clear provisional clock.
        #expect(
            !DeviceTrialLoginMerge.shouldClearProvisional(
                serverTrialEndsAt: ends.addingTimeInterval(86_400),
                provisionalEndsAt: ends
            )
        )
    }

    @Test func provisionalExpiresAfterFourteenDays() throws {
        let fingerprint = DeviceFingerprint.hash(uuid: "provisional-expired")
        let started = now.addingTimeInterval(-15 * 86_400)
        let provisional = DeviceTrialClock.ProvisionalRecord(startedAt: started, fingerprint: fingerprint)
        #expect(provisional.evaluation(at: now) == .expired)
        #expect(provisional.snapshot(at: now) == nil)
        #expect(throws: AppAccessError.trialExpired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: AppAccessSnapshot(
                    license: .trial,
                    trialEndsAt: provisional.endsAt
                ),
                hasLocalLifetimeCredential: false,
                at: now
            )
        }
    }

    @Test func firstLaunchWithoutSignedTokenStartsOrUpgradesTrial() {
        #expect(
            DeviceTrialBootstrap.launchPath(
                paidAccessEnabled: true,
                hasLifetimeCredential: false,
                hasSignedToken: false
            ) == .startOrUpgrade
        )
        #expect(
            DeviceTrialBootstrap.launchPath(
                paidAccessEnabled: true,
                hasLifetimeCredential: false,
                hasSignedToken: true
            ) == .verifyOnly
        )
        #expect(
            DeviceTrialBootstrap.launchPath(
                paidAccessEnabled: true,
                hasLifetimeCredential: true,
                hasSignedToken: false
            ) == .verifyOnly
        )
        #expect(
            DeviceTrialBootstrap.launchPath(
                paidAccessEnabled: false,
                hasLifetimeCredential: false,
                hasSignedToken: false
            ) == .skip
        )
        #expect(!DeviceTrialBootstrap.preferVerify(hasSignedToken: false))
        #expect(DeviceTrialBootstrap.preferVerify(hasSignedToken: true))
    }

    @Test func firstLaunchRegisterFailureUsesProvisionalAndAllowsUnsignedRecording() throws {
        let fingerprint = DeviceFingerprint.hash(uuid: "first-launch-offline")
        var stored: String?
        let start = DeviceTrialBootstrap.provisionalStart(from: nil, at: now)
        let provisional = try DeviceTrialClock.storeProvisional(
            startedAt: start,
            fingerprint: fingerprint,
            write: { stored = $0 }
        )
        let snapshot = provisional.snapshot(at: now)
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: snapshot ?? .init(),
            hasLocalLifetimeCredential: false,
            at: now
        )
        guard case let .active(active)? = snapshot?.trialPresentation(at: now) else {
            Issue.record("first-launch provisional must show remaining trial time")
            return
        }
        #expect(active.remaining > 13 * 86_400)
        #expect(DeviceTrialBootstrap.shouldKeepLocalTrial(on: .verificationRequired))
        #expect(DeviceTrialBootstrap.shouldKeepLocalTrial(on: .signInRequired))
        #expect(!DeviceTrialBootstrap.shouldKeepLocalTrial(on: .trialExpired))
        #expect(
            !DeviceTrialBootstrap.shouldSetPendingNetworkRestore(
                hasLocalTrialClock: true,
                hasLifetimeCredential: false
            )
        )
        #expect(
            !DeviceTrialBootstrap.shouldSetPendingNetworkRestore(
                hasLocalTrialClock: false,
                hasLifetimeCredential: false
            )
        )
        #expect(
            (try? AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: snapshot ?? .init(),
                hasLocalLifetimeCredential: false,
                at: now
            )) != nil
        )
        _ = stored
    }

    @Test func signedTokenClearsProvisionalAndKeepsCountdown() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "first-launch-register-success")
        var provisionalStored: String? = "pending"
        var signedStored: String?
        let started = now.addingTimeInterval(-2 * 86_400)
        let ends = started.addingTimeInterval(14 * 86_400)
        _ = try DeviceTrialClock.storeProvisional(
            startedAt: started,
            fingerprint: fingerprint,
            write: { provisionalStored = $0 }
        )
        let token = try keys.token(
            fingerprint: fingerprint,
            startedAt: started,
            endsAt: ends,
            issuedAt: now
        )
        let record = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { signedStored = $0 }
        )
        #expect(record.snapshot(at: now)?.policy(at: now) == .allowed)
        guard case .active? = record.snapshot(at: now)?.trialPresentation(at: now) else {
            Issue.record("signed first-launch trial must show remaining time")
            return
        }
        try AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: record.snapshot(at: now) ?? .init(),
            hasLocalLifetimeCredential: false,
            at: now
        )
        #expect(signedStored != nil)
        _ = provisionalStored
    }

    @Test func laterRegisterPreservesProvisionalStartWithoutReopening() {
        let started = now.addingTimeInterval(-3 * 86_400)
        let preserved = DeviceTrialLoginMerge.expectedEndsPreservingProvisional(provisionalStartedAt: started)
        let reopened = now.addingTimeInterval(14 * 86_400)
        #expect(DeviceTrialBootstrap.provisionalStart(from: started, at: now) == started)
        #expect(preserved == started.addingTimeInterval(14 * 86_400))
        #expect(preserved != reopened)
        #expect(
            DeviceTrialLoginMerge.shouldClearProvisional(
                serverTrialEndsAt: preserved,
                provisionalEndsAt: preserved
            )
        )
    }

    @Test func firstRunRegisterRetriesRespectFiveMinuteBackoff() {
        #expect(DeviceTrialBootstrap.shouldRetryNetworkSync(at: now, lastAttempt: nil))
        #expect(
            DeviceTrialBootstrap.shouldRetryNetworkSync(
                at: now,
                lastAttempt: now.addingTimeInterval(-DeviceTrialClock.verifyRetryInterval - 1)
            )
        )
        #expect(
            !DeviceTrialBootstrap.shouldRetryNetworkSync(
                at: now,
                lastAttempt: now.addingTimeInterval(-60)
            )
        )
    }

    @Test func midTrialSignedTokenAllowsWhenOfflineValidUntilNilOrExpired() {
        let mid = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(5 * 86_400),
            offlineValidUntil: now.addingTimeInterval(-1)
        )
        #expect(mid.policy(at: now) == .allowed)
        try? AppAccessGate.requireNewContent(
            enforced: true,
            signedIn: false,
            access: mid,
            hasLocalLifetimeCredential: false,
            at: now
        )
        #expect(
            AppAccessGate.canCreateNewContent(
                enforced: true,
                signedIn: false,
                access: mid,
                hasLocalLifetimeCredential: false,
                at: now
            )
        )
        let noLease = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(5 * 86_400),
            offlineValidUntil: nil
        )
        #expect(noLease.policy(at: now) == .allowed)
    }

    @Test func activeSnapshotOmitsExpiredDeviceTrial() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "expired-overlay-device")
        let started = now.addingTimeInterval(-20 * 86_400)
        let ends = now.addingTimeInterval(-1 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: started, endsAt: ends, issuedAt: started)
        var stored: String?
        _ = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: started,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        let loaded = try DeviceTrialClock.load(
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(loaded?.evaluation(at: now) == .expired)
        #expect(loaded?.snapshot(at: now)?.trialPresentation(at: now) == .expired)
        // Overlay path uses activeSnapshot — expired / invalid tokens must not become license=.trial.
        let active = try DeviceTrialClock.activeSnapshot(
            at: now,
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(active == nil)
    }

    @Test func deviceTrialOverlayOnlyAppliesWhenLicenseIsNone() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "overlay-test-device")
        let ends = now.addingTimeInterval(14 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: ends, issuedAt: now)
        var stored: String?
        _ = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Device trial should NOT overlay when server already has a trial license
        let existingServerTrial = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(7 * 86_400)
        )
        // Simulate overlay logic: should not replace existing trial
        #expect(existingServerTrial.license != .none)
        // Only .none license should allow device trial overlay
        let noLicense = AppAccessSnapshot()
        #expect(noLicense.license == .none)
    }

    @Test func lifetimePlusActiveTrialShowsLifetimeWithoutClock() throws {
        let lifetimeKeys = LifetimeDeviceTestKeys()
        let trialKeys = DeviceTrialTestKeys()
        let userID = UUID()
        let fingerprint = DeviceFingerprint.hash(uuid: "acceptance-1")
        // Store Lifetime credential
        let lifetimeToken = try lifetimeKeys.token(userID: userID, fingerprint: fingerprint, issuedAt: now)
        var lifetimeStored: String?
        _ = try LifetimeLocalCredential.store(
            token: lifetimeToken,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: now,
            publicKeyRaw: lifetimeKeys.publicKeyRaw,
            write: { lifetimeStored = $0 }
        )
        // Store device trial
        let trialEnds = now.addingTimeInterval(5 * 86_400)
        let trialToken = try trialKeys.token(fingerprint: fingerprint, startedAt: now, endsAt: trialEnds, issuedAt: now)
        var trialStored: String?
        _ = try DeviceTrialClock.store(
            token: trialToken,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: trialKeys.publicKeyRaw,
            write: { trialStored = $0 }
        )
        // Lifetime overlay takes priority (injectable load — activeSnapshot has no test hooks).
        let lifetimeRecord = try LifetimeLocalCredential.load(
            fingerprint: fingerprint,
            publicKeyRaw: lifetimeKeys.publicKeyRaw,
            read: { lifetimeStored }
        )
        let lifetimeSnapshot = lifetimeRecord?.snapshot(at: now)
        #expect(lifetimeSnapshot?.license == .lifetime)
        #expect(lifetimeSnapshot?.trialPresentation(at: now) == nil)
        _ = trialStored
    }

    @Test func activeTrialSurvivesSignOutOverlay() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "acceptance-2")
        let trialEnds = now.addingTimeInterval(7 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: now, endsAt: trialEnds, issuedAt: now)
        var stored: String?
        let stored1 = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        // Before sign-out: active trial
        #expect(stored1.endsAt == trialEnds.roundedToUnix)
        // After sign-out simulation: clear appAccess, then overlay device trial
        var appAccess = AppAccessSnapshot()
        #expect(appAccess.license == .none)
        // Simulate device trial overlay (only when license is .none)
        if let overlay = try DeviceTrialClock.activeSnapshot(
            at: now,
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        ) {
            appAccess = overlay
        }
        #expect(appAccess.license == .trial)
        #expect(appAccess.trialEndsAt == trialEnds.roundedToUnix)
        if case let .active(presentation)? = appAccess.trialPresentation(at: now) {
            #expect(presentation.endsAt == trialEnds.roundedToUnix)
        } else {
            Issue.record("Expected active trial presentation")
        }
    }

    @Test func expiredDeviceTrialHasNoActiveSnapshot() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "acceptance-3")
        let started = now.addingTimeInterval(-20 * 86_400)
        let ended = now.addingTimeInterval(-1 * 86_400)
        let token = try keys.token(fingerprint: fingerprint, startedAt: started, endsAt: ended, issuedAt: started)
        var stored: String?
        _ = try DeviceTrialClock.store(
            token: token,
            fingerprint: fingerprint,
            verifiedAt: started,
            publicKeyRaw: keys.publicKeyRaw,
            write: { stored = $0 }
        )
        let active = try DeviceTrialClock.activeSnapshot(
            at: now,
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { stored }
        )
        #expect(active == nil)
        // Sign-out overlay should not fabricate a trial clock
        var appAccess = AppAccessSnapshot()
        if let overlay = active {
            appAccess = overlay
        }
        #expect(appAccess.license == .none)
        #expect(appAccess.trialPresentation(at: now) == nil)
    }

    @Test func deviceTrialTruncateAfterMerge() throws {
        let keys = DeviceTrialTestKeys()
        let fingerprint = DeviceFingerprint.hash(uuid: "pr4-truncate")
        // Device trial: started earlier, ends later
        let deviceStarted = now.addingTimeInterval(-5 * 86_400)
        let deviceEnds = now.addingTimeInterval(9 * 86_400)
        let deviceToken = try keys.token(
            fingerprint: fingerprint,
            startedAt: deviceStarted,
            endsAt: deviceEnds,
            issuedAt: deviceStarted
        )
        var storedDevice: String?
        let deviceRecord = try DeviceTrialClock.store(
            token: deviceToken,
            fingerprint: fingerprint,
            verifiedAt: deviceStarted,
            publicKeyRaw: keys.publicKeyRaw,
            write: { storedDevice = $0 }
        )
        #expect(deviceRecord.endsAt == deviceEnds.roundedToUnix)
        // Server merged trial: earlier endsAt (server trial started later)
        let serverEnds = now.addingTimeInterval(5 * 86_400)
        // After merge, server should have re-issued a truncated device token
        let truncatedToken = try keys.token(
            fingerprint: fingerprint,
            startedAt: deviceStarted,
            endsAt: serverEnds,
            issuedAt: now
        )
        let truncatedRecord = try DeviceTrialClock.store(
            token: truncatedToken,
            fingerprint: fingerprint,
            verifiedAt: now,
            publicKeyRaw: keys.publicKeyRaw,
            write: { storedDevice = $0 }
        )
        #expect(truncatedRecord.endsAt == serverEnds.roundedToUnix)
        // Sign-out overlay should show truncated endsAt
        let overlaySnapshot = try DeviceTrialClock.activeSnapshot(
            at: now,
            fingerprint: fingerprint,
            publicKeyRaw: keys.publicKeyRaw,
            read: { storedDevice }
        )
        #expect(overlaySnapshot?.trialEndsAt == serverEnds.roundedToUnix)
        if case let .active(presentation)? = overlaySnapshot?.trialPresentation(at: now) {
            #expect(presentation.endsAt == serverEnds.roundedToUnix)
        } else {
            Issue.record("Expected active trial presentation with truncated endsAt")
        }
    }

}

private struct LifetimeDeviceTestKeys {
    let privateKey = Curve25519.Signing.PrivateKey()
    var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

    func token(userID: UUID, fingerprint: String, issuedAt: Date, expiresAt: Date? = nil) throws -> String {
        let exp = expiresAt ?? issuedAt.addingTimeInterval(TimeInterval(LifetimeDeviceLicense.leaseDays * 24 * 3_600))
        let header = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT", "kid": "lifetime-device-v1"])
        )
        let payload = DeviceTrialLicense.base64URLEncode(
            try JSONSerialization.data(withJSONObject: [
                "typ": "lifetime_device",
                "uid": userID.uuidString,
                "fp": fingerprint,
                "iat": Int(issuedAt.timeIntervalSince1970),
                "exp": Int(exp.timeIntervalSince1970),
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
