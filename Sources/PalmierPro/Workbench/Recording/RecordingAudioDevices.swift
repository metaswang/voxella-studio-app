import AVFoundation
import AVFAudio
import CoreAudio
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct RecordingAudioDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

enum RecordingAudioDeviceEnumerator {
    @concurrent
    static func devices() async -> [RecordingAudioDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.compactMap { device in
            let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            guard !device.uniqueID.localizedCaseInsensitiveContains("CADefaultDeviceAggregate") else {
                return nil
            }
            return RecordingAudioDevice(id: device.uniqueID, name: name)
        }
    }

    static func audioDeviceID(forUID deviceUID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else {
            return nil
        }

        for device in devices {
            if uid(for: device) == deviceUID {
                return device
            }
        }
        return nil
    }

    static func defaultInputUID() -> String? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return uid(for: deviceID)
    }

    static func resolvedInputUID(explicit: String?) -> String? {
        if let explicit { return explicit }
        guard let uid = defaultInputUID() else { return nil }
        if uid.localizedCaseInsensitiveContains("CADefaultDeviceAggregate") {
            return nil
        }
        return uid
    }

    static func prefersDefaultAudioEngine(explicitUID: String?) -> Bool {
        guard let explicitUID, !explicitUID.isEmpty else { return true }
        return explicitUID == defaultInputUID()
    }

    static func captureDevice(uniqueID: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: uniqueID)
    }

    static func resolvedMicrophone(
        _ current: RecordingMicrophoneSource,
        devices: [RecordingAudioDevice],
        defaultDeviceID: String?
    ) -> RecordingMicrophoneSource {
        let fallback: RecordingMicrophoneSource = {
            if let defaultDeviceID, devices.contains(where: { $0.id == defaultDeviceID }) {
                return .device(id: defaultDeviceID)
            }
            if let first = devices.first {
                return .device(id: first.id)
            }
            return .systemDefault
        }()

        switch current {
        case .off:
            return .off
        case .systemDefault:
            return fallback
        case .device(let id):
            if devices.contains(where: { $0.id == id }) {
                return current
            }
            return fallback
        }
    }

    private static func uid(for device: AudioDeviceID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var currentUID: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &currentUID) { pointer in
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else { return nil }
        return currentUID?.takeRetainedValue() as String?
    }
}

enum RecordingMicrophoneAuthorizationStatus: String, Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .denied
        }
    }
}

enum RecordingPermission {
    static func microphoneStatus() -> RecordingMicrophoneAuthorizationStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .authorized
        case .undetermined:
            .notDetermined
        case .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    static func tccAllowsScreenCapture() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func isScreenCapturePermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain {
            return ns.code == SCStreamError.Code.userDeclined.rawValue
        }
        return false
    }

    @concurrent
    static func canAccessShareableContent() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            Log.recording.notice(
                "shareable content probe failed preflight=\(CGPreflightScreenCaptureAccess()) error=\(Log.detail(error)) \(diagnosticContext())"
            )
            return false
        }
    }

    static func requestMicrophone() async throws {
        let initialStatus = microphoneStatus()
        Log.recording.notice(
            "microphone authorization status=\(initialStatus.rawValue) \(diagnosticContext())"
        )
        switch initialStatus {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            let finalStatus = microphoneStatus()
            Log.recording.notice(
                "microphone authorization request granted=\(granted) final=\(finalStatus.rawValue) \(diagnosticContext())"
            )
            guard granted, finalStatus == .authorized else {
                throw error(for: finalStatus)
            }
        case .denied:
            throw RecordingError.microphoneDenied
        case .restricted:
            throw RecordingError.microphoneRestricted
        }
    }

    static func requestScreenCapture(usesSystemPicker: Bool) async throws {
        if await canAccessShareableContent() {
            Log.recording.notice(
                "screen capture authorization status=authorized preflight=\(tccAllowsScreenCapture()) \(diagnosticContext())"
            )
            return
        }

        if tccAllowsScreenCapture() {
            Log.recording.notice(
                "screen capture TCC granted; shareable content probe failed picker=\(usesSystemPicker) \(diagnosticContext())"
            )
            if usesSystemPicker {
                return
            }
            throw RecordingError.screenCaptureNeedsRelaunch
        }

        Log.recording.notice(
            "screen capture authorization status=denied preflight=false; requesting access \(diagnosticContext())"
        )
        let requested = await MainActor.run { CGRequestScreenCaptureAccess() }
        if await canAccessShareableContent() {
            Log.recording.notice(
                "screen capture authorization request returned=\(requested) final=authorized preflight=\(tccAllowsScreenCapture()) \(diagnosticContext())"
            )
            return
        }

        let preflight = tccAllowsScreenCapture()
        Log.recording.notice(
            "screen capture authorization request returned=\(requested) final=denied preflight=\(preflight) picker=\(usesSystemPicker) \(diagnosticContext())"
        )
        if requested || preflight {
            if usesSystemPicker {
                return
            }
            throw RecordingError.screenCaptureNeedsRelaunch
        }
        throw RecordingError.screenCaptureDenied
    }

    private static func error(for status: RecordingMicrophoneAuthorizationStatus) -> RecordingError {
        status == .restricted ? .microphoneRestricted : .microphoneDenied
    }

    private static func diagnosticContext() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let bundlePath = Bundle.main.bundleURL.path
        return "bundle=\(bundleID) path=\(bundlePath)"
    }
}
