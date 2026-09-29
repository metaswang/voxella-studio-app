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
    ]
}

struct DetectedMeetingApp: Identifiable, Equatable, Sendable {
    var definition: MeetingAppDefinition
    var bundleIdentifier: String

    var id: String { definition.id }
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
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(observer)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    func refresh() {
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        running = MeetingAppCatalog.apps.compactMap { definition in
            guard let bundleID = definition.bundleIdentifiers.first(where: bundleIDs.contains) else { return nil }
            return DetectedMeetingApp(definition: definition, bundleIdentifier: bundleID)
        }
    }
}
