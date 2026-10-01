import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Local meeting recording")
struct LocalMeetingRecordingTests {
    // Mac meeting shortcuts do not select a USB mobile screen.
    @Test(arguments: RecordingCaptureMode.allCases.filter { $0 != .mobileDevice })
    func meetingShortcutsIncludeRemoteParticipants(mode: RecordingCaptureMode) {
        let request = LocalRecordingRequest(
            mode: mode, applicationBundleIdentifier: nil, startImmediately: true
        )
        let current = RecordingCaptureConfiguration(
            mode: .window, microphone: .device(id: "headset"), capturesSystemAudio: false
        )
        let configuration = request.configuration(from: current)

        #expect(configuration.mode == mode)
        #expect(configuration.capturesSystemAudio)
        #expect(configuration.microphone == .device(id: "headset"))
        #expect(configuration.requiresScreenCapture)
        #expect(!current.capturesSystemAudio)
    }

    @Test func microphoneOffStillCapturesTheMeetingAudio() {
        let request = LocalRecordingRequest(
            mode: .window, applicationBundleIdentifier: "us.zoom.xos", startImmediately: true
        )
        let configuration = request.configuration(from: RecordingCaptureConfiguration(
            mode: .window, microphone: .off, capturesSystemAudio: false
        ))
        #expect(configuration.capturesSystemAudio)
        #expect(configuration.hasAudioSource)
    }

    @Test func onlyAnUnambiguousAppWindowCanSkipThePicker() {
        let meeting = window(id: 1, width: 800)
        let home = window(id: 2, width: 1200)
        #expect(selected([meeting]) == 1)
        #expect(selected([meeting, home]) == nil)
        #expect(selected([home, meeting]) == nil)
        #expect(selected([]) == nil)
    }

    @Test func otherAppsHiddenWindowsAndUtilityPanelsAreExcluded() {
        let meeting = window(id: 1, width: 800)
        var otherApp = window(id: 2, width: 1400)
        otherApp.bundleIdentifier = "com.microsoft.teams2"
        var hidden = window(id: 3, width: 1400)
        hidden.isOnScreen = false
        var panel = window(id: 4, width: 1400)
        panel.layer = 1
        let small = window(id: 5, width: 200)
        #expect(selected([otherApp, hidden, panel, small]) == nil)
        #expect(selected([meeting, otherApp, hidden, panel, small]) == 1)
    }

    private func selected(_ windows: [RecordingWindowCandidate]) -> CGWindowID? {
        RecordingWindowSelection.unambiguousWindowID(in: windows, bundleIdentifier: "us.zoom.xos")
    }

    private func window(id: CGWindowID, width: CGFloat) -> RecordingWindowCandidate {
        RecordingWindowCandidate(
            id: id, bundleIdentifier: "us.zoom.xos", isOnScreen: true, layer: 0,
            frame: CGRect(x: 0, y: 0, width: width, height: 600)
        )
    }
}
