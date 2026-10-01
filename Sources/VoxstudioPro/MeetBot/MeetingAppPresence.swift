import AppKit
import Observation

struct MeetingAppDefinition: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var bundleIdentifiers: [String]
    var systemImage: String
}

enum MeetingAppCatalog {
    /// Native meeting apps that can be detected without Screen Recording permission.
    static let apps: [MeetingAppDefinition] = [
        MeetingAppDefinition(
            id: "zoom",
            name: "Zoom",
            bundleIdentifiers: ["us.zoom.xos"],
            systemImage: "video.fill"
        ),
        MeetingAppDefinition(
            id: "teams",
            name: "Microsoft Teams",
            bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"],
            systemImage: "person.2.fill"
        ),
        MeetingAppDefinition(
            id: "webex",
            name: "Webex",
            bundleIdentifiers: ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"],
            systemImage: "video.bubble.left.fill"
        ),
        MeetingAppDefinition(id: "tencent-meeting", name: "Tencent Meeting", bundleIdentifiers: ["com.tencent.meeting", "com.tencent.tencentmeeting"], systemImage: "video.fill"),
        MeetingAppDefinition(id: "lark", name: "Feishu / Lark", bundleIdentifiers: ["com.electron.lark"], systemImage: "video.fill"),
        MeetingAppDefinition(id: "dingtalk", name: "DingTalk", bundleIdentifiers: ["com.alibaba.DingTalkMac"], systemImage: "video.fill"),
        MeetingAppDefinition(id: "slack", name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], systemImage: "bubble.left.and.bubble.right.fill"),
        MeetingAppDefinition(id: "discord", name: "Discord", bundleIdentifiers: ["com.hnc.Discord"], systemImage: "headphones"),
        MeetingAppDefinition(id: "facetime", name: "FaceTime", bundleIdentifiers: ["com.apple.FaceTime"], systemImage: "video.fill"),
    ]

    static func detect(in applications: [RecordingApplicationTarget]) -> [DetectedMeetingApp] {
        apps.flatMap { definition in
            applications.filter { definition.bundleIdentifiers.contains($0.bundleIdentifier) }
                .sorted { $0.processID < $1.processID }
                .map { DetectedMeetingApp(definition: definition, bundleIdentifier: $0.bundleIdentifier,
                                         processID: $0.processID, name: $0.name) }
        }
    }
}

struct DetectedMeetingApp: Identifiable, Equatable, Sendable {
    var definition: MeetingAppDefinition
    var bundleIdentifier: String
    var processID: Int32
    var name: String

    var id: Int32 { processID }
}

@MainActor
@Observable
final class MeetingAppPresence {
    private(set) var running: [DetectedMeetingApp] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(observer)
        }
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(observer)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func refresh() {
        running = MeetingAppCatalog.detect(in: NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
            return RecordingApplicationTarget(bundleIdentifier: bundleID, processID: app.processIdentifier,
                                              name: app.localizedName ?? bundleID)
        })
    }
}
