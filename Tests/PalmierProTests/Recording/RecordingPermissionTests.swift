import AVFoundation
import Testing
@testable import PalmierPro

@Suite("Recording permissions")
struct RecordingPermissionTests {
    @Test func mapsMicrophoneAuthorizationStatuses() {
        #expect(RecordingMicrophoneAuthorizationStatus(.authorized) == .authorized)
        #expect(RecordingMicrophoneAuthorizationStatus(.notDetermined) == .notDetermined)
        #expect(RecordingMicrophoneAuthorizationStatus(.denied) == .denied)
        #expect(RecordingMicrophoneAuthorizationStatus(.restricted) == .restricted)
    }

    @Test func permissionErrorsPointToTheMatchingSettingsPane() {
        #expect(RecordingError.microphoneDenied.permissionKind == .microphone)
        #expect(RecordingError.microphoneRestricted.permissionKind == .microphone)
        #expect(RecordingError.screenCaptureDenied.permissionKind == .screenCapture)
        #expect(
            RecordingError.microphoneDenied.localizedDescription.contains("Microphone")
        )
        #expect(
            RecordingError.screenCaptureDenied.localizedDescription.contains("Screen Recording")
        )
    }

    @Test func recordingSettingsNormalizeToAnAudioSource() {
        var configuration = RecordingCaptureConfiguration(
            mode: .audioOnly,
            microphone: .off,
            capturesSystemAudio: false
        )

        #expect(!configuration.hasAudioSource)
        configuration.normalizeAudioSources()
        #expect(configuration.microphone == .systemDefault)
        #expect(configuration.hasAudioSource)
    }
}
