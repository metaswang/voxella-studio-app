import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Cloud plan transcription allowances")
struct PlanTranscriptionAllowanceTests {
    @Test func currentRatesGiveStarterOneTimesAndProFourTimesTranscription() throws {
        let starter = try #require(PlanTranscriptionAllowance(monthlyCredits: 500, creditsPerSecond: 0.013889))
        let pro = try #require(PlanTranscriptionAllowance(monthlyCredits: 1500, creditsPerSecond: 0.010417))
        #expect(abs(starter.monthlyHours - 10) < 0.001)
        #expect(abs(pro.monthlyHours - 40) < 0.002)
        #expect(starter.multiplier(comparedTo: starter) == 1)
        #expect(abs(pro.multiplier(comparedTo: starter) - 4) < 0.001)
        #expect(abs(starter.creditsPerHour - 50) < 0.002)
        #expect(abs(pro.creditsPerHour - 37.5) < 0.002)
        #expect(abs(pro.rateReduction(comparedTo: starter) - 0.25) < 0.001)
    }

    @Test func comparisonFollowsChangedCreditsAndRates() throws {
        let baseline = try #require(PlanTranscriptionAllowance(monthlyCredits: 360, creditsPerSecond: 0.01))
        let other = try #require(PlanTranscriptionAllowance(monthlyCredits: 720, creditsPerSecond: 0.02))
        #expect(other.monthlyHours == 10)
        #expect(other.multiplier(comparedTo: baseline) == 1)
        #expect(other.rateReduction(comparedTo: baseline) == -1)
    }

    @Test func missingOrInvalidBillingDataDoesNotInventAnAllowance() {
        for credits in [nil, 0, -1] as [Int?] {
            #expect(PlanTranscriptionAllowance(monthlyCredits: credits, creditsPerSecond: 0.01) == nil)
        }
        for rate in [nil, 0, -1, .nan, .infinity, .greatestFiniteMagnitude] as [Double?] {
            #expect(PlanTranscriptionAllowance(monthlyCredits: 1500, creditsPerSecond: rate) == nil)
        }
    }

    @Test func availablePlanUsesStandardTranscriptionInsteadOfCombinedOrMeetingRates() throws {
        let plan = AvailablePlan(
            tier: AccountTier(rawValue: "pro"), planID: "pro", monthlyPriceUsd: 15,
            discountedMonthlyPriceUsd: nil, monthlyBudgetCredits: 1500,
            usageRates: [
                .init(usageType: "meeting_record_transcribe", creditsPerSecond: 0.020833),
                .init(usageType: "translation", creditsPerSecond: 0.005208),
                .init(usageType: "upload_transcribe", creditsPerSecond: 0.010417),
            ]
        )
        let allowance = try #require(plan.transcriptionAllowance)
        #expect(abs(allowance.monthlyHours - 40) < 0.002)
        #expect(abs(allowance.creditsPerHour - 37.5) < 0.002)
    }

    @Test func olderAvailablePlanPayloadsRemainDecodableWithoutRates() throws {
        let data = Data(#"{"tier":"pro","planID":"pro","monthlyPriceUsd":15,"monthlyBudgetCredits":1500}"#.utf8)
        let plan = try JSONDecoder().decode(AvailablePlan.self, from: data)
        #expect(plan.usageRates == nil)
        #expect(plan.transcriptionAllowance == nil)
    }
}
