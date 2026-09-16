import Observation

@Observable
@MainActor
final class HostedCreditAvailability {
    static let shared = HostedCreditAvailability()

    private(set) var isExhausted = false

    private init() {}

    func markExhausted() {
        isExhausted = true
    }

    func clearAfterAccountRefresh() {
        isExhausted = false
    }
}
