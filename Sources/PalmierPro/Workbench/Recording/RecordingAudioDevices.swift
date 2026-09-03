import AVFoundation
import AVFAudio
import CoreAudio
import CoreGraphics
import Foundation

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

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
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

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in devices {
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var currentUID: Unmanaged<CFString>?
            let status = withUnsafeMutablePointer(to: &currentUID) { pointer in
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
            }
            guard status == noErr, let value = currentUID?.takeRetainedValue() as String? else {
                continue
            }
            if value == uid {
                return device
            }
        }
        return nil
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

    static func screenCaptureIsAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
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

    static func requestScreenCapture() throws {
        guard !screenCaptureIsAuthorized() else {
            Log.recording.notice("screen capture authorization status=authorized \(diagnosticContext())")
            return
        }

        Log.recording.notice("screen capture authorization status=denied; requesting access \(diagnosticContext())")
        let requested = CGRequestScreenCaptureAccess()
        let authorized = screenCaptureIsAuthorized()
        Log.recording.notice(
            "screen capture authorization request returned=\(requested) final=\(authorized ? "authorized" : "denied") \(diagnosticContext())"
        )
        guard requested, authorized else {
            throw RecordingError.screenCaptureDenied
        }
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
