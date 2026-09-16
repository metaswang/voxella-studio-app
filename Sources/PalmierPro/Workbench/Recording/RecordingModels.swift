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
        case .audioOnly: "Microphone, with optional system audio"
        case .display: "Entire display plus audio"
        case .window: "One window plus audio"
        case .region: "Selected area plus audio"
        }
    }

    var usesSystemPicker: Bool {
        self == .display || self == .window
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

    var requiresScreenCapturePermissionRequest: Bool {
        requiresScreenCapture && (mode == .display || !mode.usesSystemPicker)
    }

    var hasAudioSource: Bool {
        microphone.isEnabled || capturesSystemAudio
    }

    mutating func applyMode(_ newMode: RecordingCaptureMode) {
        guard newMode != mode else {
            normalizeAudioSources()
            return
        }
        let wasVideo = mode.capturesVideo
        mode = newMode
        if newMode == .audioOnly {
            capturesSystemAudio = false
            if !microphone.isEnabled {
                microphone = .systemDefault
            }
        } else if !wasVideo {
            capturesSystemAudio = true
        }
        normalizeAudioSources()
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

struct RecordingAudioMeterTick: Sendable {
    let peak: Float
    let warningLevel: RecordingAudioLevel?
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

enum RecordingRuntimeEvent: Sendable {
    case recovering(source: String, message: String)
    case recovered(source: String)
    case failed(error: RecordingError, reason: String)
    case userStopped
}

enum RecordingCaptureHealth {
    static let startupGrace: TimeInterval = 3
    static let stallTimeout: TimeInterval = 5
    static let failureTimeout: TimeInterval = 15
    static let checkInterval: TimeInterval = 1
    static let gapFillThreshold: TimeInterval = 0.05
    static let fragmentInterval: TimeInterval = 10
    static let minimumFreeBytes: Int64 = 80 * 1_024 * 1_024
    static let lowFreeBytes: Int64 = 300 * 1_024 * 1_024
}

enum RecordingLifecycleTimeout {
    static let start: TimeInterval = 25
    static let stop: TimeInterval = 20
    static let writerFinish: TimeInterval = 20
    static let termination: TimeInterval = 25
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

    static func maxSeconds(hasFeatureAccess: Bool) -> TimeInterval {
        hasFeatureAccess ? paidSeconds : freeSeconds
    }

    static func exceedsLimit(_ duration: TimeInterval, hasFeatureAccess: Bool) -> Bool {
        duration.isFinite && maxSeconds(hasFeatureAccess: hasFeatureAccess) < duration
    }

    static func recordingHint(hasFeatureAccess: Bool) -> String {
        hasFeatureAccess
            ? "Record as long as you need. Cloud processing is limited to 2 hours."
            : "Record as long as you need. Cloud processing is limited to 10 minutes on Free."
    }

    static func cloudClipNotice(hasFeatureAccess: Bool) -> String {
        hasFeatureAccess
            ? "VoxStudio Cloud can process 2 hours at a time. The clip is set to the first 2 hours. Process on this Mac to keep the full recording."
            : "VoxStudio Cloud can process 10 minutes at a time on Free. The clip is set to the first 10 minutes. Process on this Mac to keep the full recording."
    }

    static func clampedClipRange(
        duration: TimeInterval,
        current: ClosedRange<Double>?,
        hasFeatureAccess: Bool
    ) -> ClosedRange<Double> {
        let limit = maxSeconds(hasFeatureAccess: hasFeatureAccess)
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
    case screenCapturePermissionRequired
    case screenCaptureNeedsRelaunch
    case noDisplay
    case writerFailed(String)
    case captureFailed(String)
    case captureInterrupted(String)
    case diskSpaceLow
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
            "Screen Recording permission is required. Allow VoxStudio in System Settings → Privacy & Security → Screen & System Audio Recording, then try recording again."
        case .screenCapturePermissionRequired:
            "Allow Screen Recording for VoxStudio in System Settings → Privacy & Security → Screen & System Audio Recording, then return here and start recording."
        case .screenCaptureNeedsRelaunch:
            "Screen Recording is allowed, but this session cannot capture yet. Quit VoxStudio and reopen it, then start recording again."
        case .noDisplay:
            "No display is available to record."
        case .writerFailed(let message):
            "Could not write the recording: \(message)"
        case .captureFailed(let message):
            "Recording failed: \(message)"
        case .captureInterrupted(let message):
            message
        case .diskSpaceLow:
            "The disk is almost full. Recording stopped so the captured audio could be saved."
        case .emptyRecording:
            "The recording did not capture any media."
        }
    }

    var permissionKind: RecordingPermissionKind? {
        switch self {
        case .microphoneDenied, .microphoneRestricted:
            .microphone
        case .screenCaptureDenied, .screenCapturePermissionRequired:
            .screenCapture
        default:
            nil
        }
    }
}
