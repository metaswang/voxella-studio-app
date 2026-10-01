#if MAC_APP_STORE
import Foundation

/// Verified StoreKit Lifetime facts used for local MAS access.
/// Anonymous purchases unlock this Mac immediately and are not sent to the account API.
struct MASLifetimeFact: Equatable, Sendable {
    var productID: String
    var originalID: String
    var purchaseDate: Date
    var appAccountToken: UUID?
    var revoked: Bool
    var signedTransaction: String
}

enum MASLifetimePolicy {
    static func localAccess(
        _ accountAccess: AppAccessSnapshot,
        hasStoreKitLifetime: Bool
    ) -> AppAccessSnapshot {
        guard accountAccess.license == .lifetime,
              accountAccess.purchaseSources.contains(.appStore),
              !accountAccess.purchaseSources.contains(.web),
              !hasStoreKitLifetime else { return accountAccess }
        return AppAccessSnapshot(
            license: accountAccess.trialEndsAt.map { $0 > .now } == true ? .trial : .none,
            trialEndsAt: accountAccess.trialEndsAt,
            subscriptionTier: accountAccess.subscriptionTier,
            subscriptionEndsAt: accountAccess.subscriptionEndsAt,
            purchaseSources: accountAccess.purchaseSources,
            subscriptionSource: accountAccess.subscriptionSource,
            offlineValidUntil: accountAccess.offlineValidUntil
        )
    }

    static func isUnlocked(_ facts: [MASLifetimeFact], lifetimeProductID: String) -> Bool {
        facts.contains { $0.productID == lifetimeProductID && !$0.revoked }
    }

    /// Shown only after an explicit sign-in. A transaction already stamped with this account is not offered again.
    static func linkOffer(
        signedInUserID: UUID?,
        facts: [MASLifetimeFact],
        lifetimeProductID: String
    ) -> MASLifetimeFact? {
        guard signedInUserID != nil else { return nil }
        return facts.first {
            $0.productID == lifetimeProductID && !$0.revoked && $0.appAccountToken == nil
        }
    }
}
#endif
