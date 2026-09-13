import Foundation

struct AppAccessRefreshSchedule {
    static let interval: TimeInterval = 6 * 60 * 60
    static let retryInterval: TimeInterval = 5 * 60
    private(set) var lastSuccess: Date?
    private(set) var lastAttempt: Date?

    func isDue(at date: Date) -> Bool {
        if let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
        return lastSuccess.map { date.timeIntervalSince($0) >= Self.interval } ?? true
    }

    mutating func attempted(at date: Date) { lastAttempt = date }
    mutating func succeeded(at date: Date) { lastSuccess = date }

    static func permitsOfflineFallback(_ error: Error) -> Bool {
        error is URLError || (error as? VoxellaAuthError) == .refreshUnavailable
    }

    static func invalidatesSession(_ error: Error) -> Bool {
        if let error = error as? VoxellaAuthError {
            return [.unauthorized, .refreshFailed, .missingRefreshToken].contains(error)
        }
        return (error as? VoxellaAPIError) == .unauthorized
    }
}
