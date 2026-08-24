import Testing
@testable import PalmierPro

@Suite("Meet Bot account access")
struct AccountFeatureTests {
    @Test("Free and unknown plans cannot use Starter features")
    func freeAndUnknownPlansAreDenied() {
        #expect(AccountTier(rawValue: "free").subscriptionRank == 0)
        #expect(AccountTier(rawValue: "unknown_plan").subscriptionRank == 0)
        #expect(!AccountTier(rawValue: "free").satisfies(AccountTier(rawValue: "starter")))
        #expect(!AccountTier(rawValue: "unknown_plan").satisfies(AccountTier(rawValue: "starter")))
    }

    @Test("Basic is equivalent to Starter and paid tiers remain eligible")
    func starterRankMatchesBackendMatrix() {
        let minimum = AccountFeature.meetBot.minimumPlan

        #expect(AccountTier(rawValue: "basic").satisfies(minimum))
        #expect(AccountTier(rawValue: "starter").satisfies(minimum))
        #expect(AccountTier(rawValue: "pro").satisfies(minimum))
        #expect(AccountTier(rawValue: "team").satisfies(minimum))
        #expect(AccountTier(rawValue: "ultra").satisfies(minimum))
        #expect(AccountTier(rawValue: "enterprise").satisfies(minimum))
    }
}
