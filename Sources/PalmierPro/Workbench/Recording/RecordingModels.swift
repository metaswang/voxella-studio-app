import CoreGraphics
import Foundation

enum RecordingCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case audioOnly
    case display
    case window
    case region

    var id: String { rawValue }

    var capturesVideo: Bool {
        self != .audioOnly
    }

    var title: String {
        switch self {
        case .audioOnly: "Audio"
        case .display: "Display"
        case .window: "Window"
        case .region: "Region"
        }
    }

    var systemImage: String {
        switch self {
        case .audioOnly: "mic"
        case .display: "display"
        case .window: "macwindow"
        case .region: "rectangle.dashed"
        }
    }

    var detail: String {
        switch self {
        case .audioOnly: "Microphone and/or system audio"
        case .display: "Entire display plus audio"
        case .window: "One window plus audio"
        case .region: "Selected area plus audio"
        }
    }
}

enum RecordingMicrophoneSource: Equatable, Hashable, Sendable {
    case off
    case systemDefault
    case device(id: String)

    var isEnabled: Bool { self != .off }

    var deviceID: String? {
        switch self {
        case .off: nil
        case .systemDefault: nil
        case .device(let id): id
        }
    }
}

struct RecordingCaptureConfiguration: Equatable, Sendable {
    var mode: RecordingCaptureMode = .display
    var microphone: RecordingMicrophoneSource = .systemDefault
    var capturesSystemAudio = true

    var capturesVideo: Bool { mode.capturesVideo }

    var requiresScreenCapture: Bool {
        capturesVideo || capturesSystemAudio
    }

    var hasAudioSource: Bool {
        microphone.isEnabled || capturesSystemAudio
    }

    mutating func normalizeAudioSources() {
        guard !hasAudioSource else { return }
        if capturesVideo {
            capturesSystemAudio = true
            microphone = .systemDefault
        } else {
            microphone = .systemDefault
        }
    }
}

struct RecordingAudioLevel: Equatable, Sendable {
    let duration: TimeInterval
    let rmsDBFS: Double
    let peakDBFS: Double

    var isLowLevel: Bool {
        duration >= 0.25 && rmsDBFS < -40
    }
}

enum RecordingAudioTrack: String, Sendable {
    case microphone
    case systemAudio

    var title: String {
        switch self {
        case .microphone: "microphone"
        case .systemAudio: "system audio"
        }
    }
}

struct RecordingAudioLevelWarning: Sendable {
    let track: RecordingAudioTrack
    let level: RecordingAudioLevel

    var message: String {
        switch track {
        case .microphone:
            "The microphone level has been low for several seconds. Move closer to the microphone or raise the input volume."
        case .systemAudio:
            "The system audio level has been low for several seconds. Raise the Mac playback volume or choose a source that is playing audio."
        }
    }
}

struct RecordingSessionDiagnostics: Equatable, Sendable {
    let microphone: RecordingAudioLevel?
    let systemAudio: RecordingAudioLevel?

    var warningMessage: String? {
        let microphoneLow = microphone?.isLowLevel == true
        let systemAudioLow = systemAudio?.isLowLevel == true
        let microphonePresent = microphone != nil
        let systemAudioPresent = systemAudio != nil
        if microphonePresent && systemAudioPresent {
            guard microphoneLow && systemAudioLow else { return nil }
        }
        var lowTracks: [String] = []
        if microphoneLow { lowTracks.append("microphone") }
        if systemAudioLow { lowTracks.append("system audio") }
        guard !lowTracks.isEmpty else { return nil }
        let trackList = lowTracks.joined(separator: " and ")
        return "The recording level was low for \(trackList). Move closer to the microphone or raise the source volume before recording again."
    }
}

struct RecordingStopResult: Sendable {
    let url: URL
    let diagnostics: RecordingSessionDiagnostics
}

enum RecordingPhase: Equatable, Sendable {
    case idle
    case preparing
    case picking
    case recording
    case paused
    case finishing

    var isActive: Bool {
        switch self {
        case .idle: false
        case .preparing, .picking, .recording, .paused, .finishing: true
        }
    }

    var isCapturing: Bool {
        self == .recording || self == .paused
    }
}

enum RecordingDurationLimit {
    static let freeSeconds: TimeInterval = 10 * 60
    static let paidSeconds: TimeInterval = 2 * 60 * 60

    static func maxSeconds(isPaid: Bool) -> TimeInterval {
        isPaid ? paidSeconds : freeSeconds
    }

    static func exceedsLimit(_ duration: TimeInterval, isPaid: Bool) -> Bool {
        duration.isFinite && duration > maxSeconds(isPaid: isPaid)
    }

    static func recordingHint(isPaid: Bool) -> String {
        isPaid
            ? "Record as long as you need. Cloud processing is limited to 2 hours."
            : "Record as long as you need. Cloud processing is limited to 10 minutes on Free."
    }

    static func cloudClipNotice(isPaid: Bool) -> String {
        isPaid
            ? "VoxStudio Cloud can process 2 hours at a time. The clip is set to the first 2 hours. Process on this Mac to keep the full recording."
            : "VoxStudio Cloud can process 10 minutes at a time on Free. The clip is set to the first 10 minutes. Process on this Mac to keep the full recording."
    }

    static func clampedClipRange(
        duration: TimeInterval,
        current: ClosedRange<Double>?,
        isPaid: Bool
    ) -> ClosedRange<Double> {
        let limit = maxSeconds(isPaid: isPaid)
        let endBound = max(0, duration)
        let maxSpan = min(limit, endBound)
        guard maxSpan > 0 else { return 0...max(endBound, 0.001) }
        guard let current else { return 0...maxSpan }

        var start = min(max(0, current.lowerBound), endBound)
        var end = min(max(start, current.upperBound), endBound)
        if end - start > maxSpan {
            end = min(endBound, start + maxSpan)
            start = max(0, end - maxSpan)
        }
        if end <= start {
            return 0...maxSpan
        }
        return start...end
    }
}

enum RecordingTimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

struct RecordingRegionSelection: Sendable {
    var displayID: UInt32
    var sourceRect: CGRect
}

enum RecordingPermissionKind: Equatable, Sendable {
    case microphone
    case screenCapture

    var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenCapture:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

enum RecordingError: LocalizedError, Equatable, Sendable {
    case cancelled
    case alreadyRecording
    case audioSourceRequired
    case microphoneDenied
    case microphoneRestricted
    case screenCaptureDenied
    case noDisplay
    case writerFailed(String)
    case captureFailed(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Recording cancelled."
        case .alreadyRecording:
            "A recording is already in progress."
        case .audioSourceRequired:
            "Choose a microphone or system audio before recording."
        case .microphoneDenied:
            "Microphone access is denied. Allow it in System Settings → Privacy & Security → Microphone, then retry."
        case .microphoneRestricted:
            "Microphone access is restricted by macOS or device management."
        case .screenCaptureDenied:
            "Screen Recording access is denied. Allow it in System Settings → Privacy & Security → Screen Recording, then retry."
        case .noDisplay:
            "No display is available to record."
        case .writerFailed(let message):
            "Could not write the recording: \(message)"
        case .captureFailed(let message):
            "Recording failed: \(message)"
        case .emptyRecording:
            "The recording did not capture any media."
        }
    }

    var permissionKind: RecordingPermissionKind? {
        switch self {
        case .microphoneDenied, .microphoneRestricted:
            .microphone
        case .screenCaptureDenied:
            .screenCapture
        default:
            nil
        }
    }
}
