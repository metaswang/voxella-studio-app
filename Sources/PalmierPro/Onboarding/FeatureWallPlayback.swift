import Foundation
import Observation

@MainActor
@Observable
final class FeatureWallPlayback {
    private(set) var isPaused = false
    private(set) var isRunning = false
    private var isVisible = false
    private var isApplicationActive = false
    private var reduceMotion = false
    private var accumulatedTime: TimeInterval = 0
    private var startedAt: Date?

    func appear(applicationActive: Bool, reduceMotion: Bool, at date: Date = Date()) {
        isVisible = true
        isApplicationActive = applicationActive
        self.reduceMotion = reduceMotion
        reconcile(at: date)
    }

    func disappear(at date: Date = Date()) {
        isVisible = false
        reconcile(at: date)
    }

    func setApplicationActive(_ active: Bool, at date: Date = Date()) {
        isApplicationActive = active
        reconcile(at: date)
    }

    func setReduceMotion(_ reduced: Bool, at date: Date = Date()) {
        reduceMotion = reduced
        reconcile(at: date)
    }

    func togglePause(at date: Date = Date()) {
        isPaused.toggle()
        reconcile(at: date)
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulatedTime + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    private func reconcile(at date: Date) {
        let shouldRun = isVisible && isApplicationActive && !reduceMotion && !isPaused
        guard shouldRun != isRunning else { return }
        accumulatedTime = elapsed(at: date)
        startedAt = shouldRun ? date : nil
        isRunning = shouldRun
    }
}
