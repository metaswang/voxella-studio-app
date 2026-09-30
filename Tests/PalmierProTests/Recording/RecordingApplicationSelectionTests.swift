import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Testing
@testable import PalmierPro

@Suite("Recording application selection")
struct RecordingApplicationSelectionTests {
    private let meeting = RecordingApplicationTarget(bundleIdentifier: "us.zoom.xos", processID: 10, name: "Zoom")
    private let browser = RecordingApplicationTarget(bundleIdentifier: "com.apple.Safari", processID: 20, name: "Safari")
    private let displays = [RecordingApplicationDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                            RecordingApplicationDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))]

    @Test func windowsDetermineDisplayCandidatesWithoutSizeHeuristics() {
        let candidates = resolve([window(10, x: 900), window(20, x: 1100)])
        #expect(candidates.first { $0.id == 10 }?.displayIDs == [1, 2])
        #expect(candidates.first { $0.id == 20 }?.displayIDs == [2])
        #expect(RecordingApplicationSelectionResolver.validate(.init(displayID: 2, applications: [meeting, browser]), candidates: candidates))
        #expect(!RecordingApplicationSelectionResolver.validate(.init(displayID: 1, applications: [meeting, browser]), candidates: candidates))
        #expect(!RecordingApplicationSelectionResolver.validate(.init(displayID: 2, applications: []), candidates: candidates))
    }

    @Test func hiddenWindowsPanelsAndTheRecorderAreNotCandidates() {
        var hidden = window(10, x: 0); hidden.isOnScreen = false
        var panel = window(20, x: 0); panel.layer = 1
        #expect(resolve([hidden, panel]).isEmpty)
        #expect(resolve([window(10, x: 0)], excluded: meeting.bundleIdentifier).isEmpty)
        // A small app window remains eligible; the meeting-window size heuristic is not used.
        var small = window(10, x: 0); small.frame.size = CGSize(width: 80, height: 60)
        #expect(resolve([small]).map(\.id) == [10])
    }

    @Test func refreshRejectsMovedOrRestartedTargets() {
        let selection = RecordingApplicationSelection(displayID: 1, applications: [meeting])
        #expect(!RecordingApplicationSelectionResolver.validate(selection, candidates: resolve([window(10, x: 1200)])))
        var restarted = meeting; restarted.processID = 11
        let current = [RecordingApplicationCandidate(application: restarted, displayIDs: [1])]
        #expect(!RecordingApplicationSelectionResolver.validate(selection, candidates: current))
        #expect(selection.survivingApplications(in: [restarted]).isEmpty)
    }

    @Test func recoveryKeepsOnlyOriginallySelectedInstances() {
        let selection = RecordingApplicationSelection(displayID: 1, applications: [meeting, browser])
        let unrelated = RecordingApplicationTarget(bundleIdentifier: "com.apple.Notes", processID: 30, name: "Notes")
        #expect(selection.survivingApplications(in: [browser, unrelated]) == [browser])
        var reusedPID = meeting; reusedPID.bundleIdentifier = unrelated.bundleIdentifier
        #expect(selection.survivingApplications(in: [reusedPID]).isEmpty)
        #expect(selection.survivingApplications(in: []).isEmpty)
    }

    @Test func appRecordingRequestsPermissionAndPreservesMicrophoneOff() {
        let request = LocalRecordingRequest(mode: .application, applicationBundleIdentifier: meeting.bundleIdentifier,
                                            startImmediately: true, applicationProcessID: meeting.processID)
        let config = request.configuration(from: .init(mode: .audioOnly, microphone: .off, capturesSystemAudio: false))
        #expect(config.microphone == .off)
        #expect(config.capturesSystemAudio)
        #expect(config.capturesVideo)
        #expect(config.requiresScreenCapturePermissionRequest)
        #expect(!config.mode.usesSystemPicker)
    }

    @Test @MainActor func applicationRecorderCopyIsLocalized() throws {
        let suite = "RecordingApplicationLocalization-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh-Hans", forKey: AppLanguage.defaultsKey)
        let localization = AppLocalization(defaults: defaults, resourceBundle: BundledResource.bundle, preferredLanguages: ["en"])
        #expect(localization.string(key: "App") == "应用")
        #expect(localization.string(key: "Choose apps to record") == "选择要录制的应用")
        #expect(localization.string(key: "Record this app") == "录制此应用")
        #expect(localization.string(key: "Microphone off") == "麦克风已关闭")
    }

    @Test func staticAndBlankCallbacksDoNotTripVideoFreeze() {
        #expect(!RecordingVideoHealth.shouldFail(now: 100, lastCallback: 99, lastCompleteFrame: 60, lastAppend: 60))
        #expect(RecordingVideoHealth.shouldFail(now: 100, lastCallback: 60, lastCompleteFrame: 60, lastAppend: 60))
        #expect(RecordingVideoHealth.shouldFail(now: 100, lastCallback: 99, lastCompleteFrame: 99, lastAppend: 60))
        #expect(!RecordingVideoHealth.shouldFail(now: 100, lastCallback: 99, lastCompleteFrame: 99, lastAppend: 99))
        // A static stream can omit callbacks; its clock-driven repeat still writes.
        #expect(!RecordingVideoHealth.shouldFail(now: 100, lastCallback: 60, lastCompleteFrame: 60,
                                                lastAppend: 99, frameAction: .repeatImage))
        #expect(RecordingVideoHealth.shouldFail(now: 100, lastCallback: 60, lastCompleteFrame: 60,
                                               lastAppend: 60, frameAction: .repeatImage))
        #expect(!RecordingVideoHealth.shouldFail(now: 100, lastCallback: 60, lastCompleteFrame: 60,
                                                lastAppend: 99, frameAction: .black))
        #expect(RecordingVideoHealth.frameAction(status: .idle, applicationMode: true) == .repeatImage)
        #expect(RecordingVideoHealth.frameAction(status: .blank, applicationMode: true) == .black)
        #expect(RecordingVideoHealth.frameAction(status: .suspended, applicationMode: true) == .black)
        #expect(RecordingVideoHealth.frameAction(status: .complete, applicationMode: true) == .image)
        #expect(RecordingVideoHealth.frameAction(status: .stopped, applicationMode: true) == .ignore)
    }

    @Test func staleIdleTimestampsStillAdvanceVideoAlongsideAudio() {
        let lastChangedFrame = CMTime(seconds: 10, preferredTimescale: 600)
        let firstTick = CMTime(seconds: 40, preferredTimescale: 600)
        let nextTick = CMTime(seconds: 41, preferredTimescale: 600)
        for status in [SCFrameStatus.idle, .blank, .suspended] {
            let action = RecordingVideoHealth.frameAction(status: status, applicationMode: true)
            let first = RecordingVideoHealth.frameTimestamp(action: action, sampleTime: lastChangedFrame, hostTime: firstTick)
            let next = RecordingVideoHealth.frameTimestamp(action: action, sampleTime: lastChangedFrame, hostTime: nextTick)
            #expect(first == firstTick)
            #expect(next > first)
            #expect(next == nextTick)
        }
        #expect(RecordingVideoHealth.frameTimestamp(action: .image, sampleTime: lastChangedFrame, hostTime: nextTick) == lastChangedFrame)
    }

    private func resolve(_ windows: [RecordingApplicationWindow], excluded: String? = nil) -> [RecordingApplicationCandidate] {
        RecordingApplicationSelectionResolver.candidates(applications: [meeting, browser], windows: windows,
                                                         displays: displays, excludedBundleIdentifier: excluded)
    }

    private func window(_ processID: Int32, x: CGFloat) -> RecordingApplicationWindow {
        RecordingApplicationWindow(processID: processID, isOnScreen: true, layer: 0,
                                   frame: CGRect(x: x, y: 100, width: 200, height: 200))
    }
}
