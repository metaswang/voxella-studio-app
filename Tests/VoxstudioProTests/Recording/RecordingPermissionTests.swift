import AVFoundation
import ScreenCaptureKit
import Testing
@testable import VoxstudioPro

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
        #expect(
            RecordingError.screenCaptureDenied.localizedDescription.contains("Screen & System Audio Recording")
        )
        #expect(RecordingError.screenCaptureNeedsRelaunch.permissionKind == nil)
        #expect(
            RecordingError.screenCaptureNeedsRelaunch.localizedDescription.contains("Quit VoxStudio")
        )
        #expect(RecordingCaptureMode.display.usesSystemPicker)
        #expect(RecordingCaptureMode.window.usesSystemPicker)
        #expect(!RecordingCaptureMode.region.usesSystemPicker)
        #expect(!RecordingCaptureMode.audioOnly.usesSystemPicker)
    }

    @Test func referenceVoicePermissionErrorsOfferMicrophoneSettings() {
        #expect(VoiceLibraryError.microphoneDenied.requiresMicrophonePermissionSettings)
        #expect(VoiceLibraryError.microphoneRestricted.requiresMicrophonePermissionSettings)
        #expect(RecordingPermission.microphoneSettingsURL?.absoluteString.contains("Privacy_Microphone") == true)
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
        #expect(!configuration.requiresScreenCapture)
    }

    @Test func audioOnlyModeDoesNotRequireScreenCaptureUnlessSystemAudioIsOn() {
        var configuration = RecordingCaptureConfiguration(
            mode: .display,
            microphone: .systemDefault,
            capturesSystemAudio: true
        )
        #expect(configuration.requiresScreenCapture)

        configuration.applyMode(.audioOnly)
        #expect(configuration.mode == .audioOnly)
        #expect(configuration.microphone == .systemDefault)
        #expect(!configuration.capturesSystemAudio)
        #expect(!configuration.requiresScreenCapture)

        configuration.capturesSystemAudio = true
        #expect(configuration.requiresScreenCapture)
        configuration.applyMode(.audioOnly)
        #expect(configuration.capturesSystemAudio)

        configuration.applyMode(.display)
        #expect(configuration.mode == .display)
        #expect(configuration.capturesSystemAudio)
        #expect(configuration.requiresScreenCapture)
    }

    @Test func displayAndRegionRequirePermissionToExcludeRecordingControls() {
        var configuration = RecordingCaptureConfiguration(
            mode: .display,
            microphone: .systemDefault,
            capturesSystemAudio: true
        )

        #expect(configuration.requiresScreenCapture)
        #expect(configuration.requiresScreenCapturePermissionRequest)

        configuration.mode = .window
        #expect(!configuration.requiresScreenCapturePermissionRequest)

        configuration.mode = .region
        #expect(configuration.requiresScreenCapturePermissionRequest)

        configuration.mode = .audioOnly
        #expect(configuration.requiresScreenCapturePermissionRequest)

        configuration.capturesSystemAudio = false
        #expect(!configuration.requiresScreenCapture)
        #expect(!configuration.requiresScreenCapturePermissionRequest)
    }

    @Test func streamStartPermissionErrorsMapToScreenCaptureErrors() {
        let declined = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )
        let mapped = RecordingPermission.captureStartError(declined)
        #expect(mapped == .screenCaptureDenied || mapped == .screenCaptureNeedsRelaunch)

        let other = NSError(domain: "test.recording", code: 1)
        guard case .captureFailed(let message) = RecordingPermission.captureStartError(other) else {
            Issue.record("expected captureFailed for a non-permission stream error")
            return
        }
        #expect(message.contains("test.recording"))

        let tcc = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"]
        )
        #expect(RecordingPermission.isScreenCapturePermissionDenied(tcc))
    }
}
