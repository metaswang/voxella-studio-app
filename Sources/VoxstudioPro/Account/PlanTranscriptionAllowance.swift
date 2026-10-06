import Foundation

struct PlanTranscriptionAllowance: Equatable, Sendable {
    let creditsPerHour: Double
    let monthlyHours: Double

    init?(monthlyCredits: Int?, creditsPerSecond: Double?) {
        guard let monthlyCredits, monthlyCredits > 0,
              let creditsPerSecond, creditsPerSecond.isFinite, creditsPerSecond > 0 else { return nil }
        let hourlyRate = creditsPerSecond * 3600
        let hours = Double(monthlyCredits) / hourlyRate
        guard hourlyRate.isFinite, hourlyRate > 0, hours.isFinite, hours > 0 else { return nil }
        creditsPerHour = hourlyRate
        monthlyHours = hours
    }

    func multiplier(comparedTo baseline: Self) -> Double {
        monthlyHours / baseline.monthlyHours
    }

    func rateReduction(comparedTo baseline: Self) -> Double {
        1 - creditsPerHour / baseline.creditsPerHour
    }
}
