import Testing
@testable import PalmierPro

@Suite("Meeting app presence")
struct MeetingAppPresenceTests {
    @Test func catalogDetectsSupportedNativeAppsAndRejectsHelpers() {
        let ids = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark",
                   "com.cisco.webexmeetingsapp", "com.tencent.meeting", "com.tencent.tencentmeeting",
                   "com.electron.lark", "com.alibaba.DingTalkMac", "com.tinyspeck.slackmacgap",
                   "com.hnc.Discord", "com.apple.FaceTime"]
        let supported = ids.enumerated().map { RecordingApplicationTarget(bundleIdentifier: $0.element,
                                                                         processID: Int32($0.offset + 1), name: $0.element) }
        let helpers = [RecordingApplicationTarget(bundleIdentifier: "us.zoom.xos.helper", processID: 100, name: "Zoom"),
                       RecordingApplicationTarget(bundleIdentifier: "com.apple.Safari", processID: 101, name: "Google Meet")]
        #expect(MeetingAppCatalog.detect(in: supported + helpers).count == ids.count)
        #expect(MeetingAppCatalog.detect(in: helpers).isEmpty)
    }

    @Test func instancesWithTheSameBundleIDRemainDistinct() {
        let first = RecordingApplicationTarget(bundleIdentifier: "com.electron.lark", processID: 10, name: "Feishu")
        let second = RecordingApplicationTarget(bundleIdentifier: "com.electron.lark", processID: 20, name: "Lark")
        let detected = MeetingAppCatalog.detect(in: [second, first])
        #expect(detected.map(\.id) == [10, 20])
        #expect(detected.map(\.name) == ["Feishu", "Lark"])
        #expect(MeetingAppCatalog.detect(in: [second]).map(\.id) == [20])
        #expect(MeetingAppCatalog.detect(in: []).isEmpty)
    }
}
