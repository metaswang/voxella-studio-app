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

    @Test func signedOutUserCannotCreateNewContent() {
        let access = AppAccessSnapshot(
            license: .trial,
            trialEndsAt: now.addingTimeInterval(86400)
        )
        #expect(!AppAccessGate.canCreateNewContent(
            enforced: true,
            signedIn: false,
            access: access,
            at: now
        ))
        #expect(throws: AppAccessError.signInRequired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: access,
                at: now
            )
        }
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
}
