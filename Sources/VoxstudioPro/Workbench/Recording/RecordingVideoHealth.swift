import Foundation
import CoreMedia
import ScreenCaptureKit

enum RecordingVideoHealth {
    enum FrameAction: Equatable { case image, repeatImage, black, ignore }

    static func frameAction(status: SCFrameStatus?, applicationMode: Bool) -> FrameAction {
        switch status {
        case .complete, .started, nil: .image
        case .idle: applicationMode ? .repeatImage : .ignore
        case .blank, .suspended: applicationMode ? .black : .ignore
        default: .ignore
        }
    }

    static func frameTimestamp(action: FrameAction, sampleTime: CMTime, hostTime: CMTime) -> CMTime {
        // Idle callbacks can carry the last changed frame's timestamp. Reusing
        // it makes fragmented video stop advancing while audio keeps writing.
        action == .image ? sampleTime : hostTime
    }
    /// Idle/blank/suspended callbacks are healthy even when there is no new image.
    /// Complete frames that cannot reach the writer still indicate a write failure.
    static func shouldFail(now: TimeInterval, lastCallback: TimeInterval,
                           lastCompleteFrame: TimeInterval, lastAppend: TimeInterval,
                           frameAction: FrameAction = .image) -> Bool {
        let timeout = RecordingCaptureHealth.videoFreezeTimeout
        let staticFrame = frameAction == .repeatImage || frameAction == .black
        let missingCallbacks = !staticFrame && now - lastCallback >= timeout
        let writerStalled = (staticFrame || now - lastCompleteFrame < RecordingCaptureHealth.stallTimeout)
            && now - lastAppend >= timeout
        return missingCallbacks || writerStalled
    }
}
