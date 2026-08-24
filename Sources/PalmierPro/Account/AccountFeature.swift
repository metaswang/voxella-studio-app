import Foundation

enum AccountFeature: String, Sendable {
    case meetBot
    case calendarSettings

    var minimumPlan: AccountTier {
        .init(rawValue: "starter")
    }
}

enum AccountFeatureAccess: Equatable, Sendable {
    case signedOut
    case upgradeRequired(minimumPlan: AccountTier)
    case allowed
}

extension AccountTier {
    var subscriptionRank: Int {
        switch rawValue {
        case "starter", "basic": 1
        case "pro": 2
        case "team", "ultra", "enterprise": 3
        default: 0
        }
    }

    func satisfies(_ minimum: AccountTier) -> Bool {
        subscriptionRank >= minimum.subscriptionRank
    }
}

extension AccountService {
    func prepareFeatureAccess(_ feature: AccountFeature) async -> AccountFeatureAccess {
        await refreshAccountForFeatureAccess()
        guard isSignedIn else { return .signedOut }
        guard tier.satisfies(feature.minimumPlan) else {
            return .upgradeRequired(minimumPlan: feature.minimumPlan)
        }
        return .allowed
    }

    func subscribeToMinimumPlan(for feature: AccountFeature) async {
        let candidates = availablePlans
            .filter { $0.tier.satisfies(feature.minimumPlan) }
            .sorted {
                if $0.effectiveMonthlyPriceUsd != $1.effectiveMonthlyPriceUsd {
                    return $0.effectiveMonthlyPriceUsd < $1.effectiveMonthlyPriceUsd
                }
                return $0.tier.subscriptionRank < $1.tier.subscriptionRank
            }
        guard let plan = candidates.first else { return }
        await subscribe(tier: plan.tier)
    }

}
