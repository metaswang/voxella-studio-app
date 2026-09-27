#if MAC_APP_STORE
import Foundation
import Testing
@testable import PalmierPro

struct MASLifetimePolicyTests {
    private let product = "com.voxella.studio.lifetime"
    private let user = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func fact(
        token: UUID? = nil,
        revoked: Bool = false,
        originalID: String = "orig-1"
    ) -> MASLifetimeFact {
        MASLifetimeFact(
            productID: product,
            originalID: originalID,
            purchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            appAccountToken: token,
            revoked: revoked,
            signedTransaction: "jws-\(originalID)"
        )
    }

    @Test func anonymousPurchaseUnlocksWithoutAnAccountRoute() {
        #expect(MASLifetimePolicy.isUnlocked([fact()], lifetimeProductID: product))
        #expect(MASLifetimePolicy.linkOffer(signedInUserID: nil, facts: [fact()], lifetimeProductID: product) == nil)
    }

    @Test func signedInPurchaseKeepsTheAccountRoute() {
        let stamped = fact(token: user)
        #expect(MASLifetimePolicy.linkOffer(signedInUserID: user, facts: [stamped], lifetimeProductID: product) == nil)
    }

    @Test func cancelledOrPendingFactsDoNotUnlock() {
        #expect(MASLifetimePolicy.isUnlocked([], lifetimeProductID: product) == false)
    }

    @Test func restartAndRestoreReuseTheSameVerifiedFacts() {
        let facts = [fact()]
        #expect(MASLifetimePolicy.isUnlocked(facts, lifetimeProductID: product))
        #expect(MASLifetimePolicy.isUnlocked(facts, lifetimeProductID: product))
    }

    @Test func refundRemovesLocalUnlock() {
        #expect(MASLifetimePolicy.isUnlocked([fact(revoked: true)], lifetimeProductID: product) == false)
    }

    @Test func accountBoundAppleLifetimeRequiresStoreKitForLocalAccess() {
        let apple = AppAccessSnapshot(license: .lifetime, purchaseSources: [.appStore])
        #expect(MASLifetimePolicy.localAccess(apple, hasStoreKitLifetime: false).license == .none)
        #expect(MASLifetimePolicy.localAccess(apple, hasStoreKitLifetime: true).license == .lifetime)
        let web = AppAccessSnapshot(license: .lifetime, purchaseSources: [.web])
        #expect(MASLifetimePolicy.localAccess(web, hasStoreKitLifetime: false).license == .lifetime)
    }

    @Test func anonymousLinkIsOfferedOncePerUnstampedTransaction() {
        let offer = MASLifetimePolicy.linkOffer(signedInUserID: user, facts: [fact()], lifetimeProductID: product)
        #expect(offer?.signedTransaction == "jws-orig-1")
        #expect(MASLifetimePolicy.linkOffer(signedInUserID: user, facts: [fact(token: user)], lifetimeProductID: product) == nil)
    }
}
#endif
