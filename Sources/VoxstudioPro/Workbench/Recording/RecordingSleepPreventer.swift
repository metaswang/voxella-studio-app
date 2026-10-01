import Foundation

final class RecordingSleepPreventer: @unchecked Sendable {
    private var activity: NSObjectProtocol?

    func start() {
        stop()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
                .userInitiated,
            ],
            reason: "VoxStudio is recording"
        )
        Log.recording.notice("recording idle sleep prevention started")
    }

    func stop() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        Log.recording.notice("recording idle sleep prevention stopped")
    }
}
