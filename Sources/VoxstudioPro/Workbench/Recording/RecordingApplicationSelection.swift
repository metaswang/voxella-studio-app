import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct RecordingApplicationTarget: Identifiable, Equatable, Hashable, Sendable {
    var bundleIdentifier: String
    var processID: Int32
    var name: String

    var id: Int32 { processID }

    func matches(_ other: Self) -> Bool {
        processID == other.processID && bundleIdentifier == other.bundleIdentifier
    }
}

struct RecordingApplicationSelection: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var applications: [RecordingApplicationTarget]

    /// Reconnection may lose an app, but cannot attach to a newly launched instance.
    func survivingApplications(in available: [RecordingApplicationTarget]) -> [RecordingApplicationTarget] {
        applications.filter { selected in available.contains { selected.matches($0) } }
    }
}

struct RecordingApplicationCandidate: Identifiable, Equatable, Sendable {
    var application: RecordingApplicationTarget
    var displayIDs: Set<CGDirectDisplayID>
    var id: Int32 { application.id }
}

struct RecordingApplicationDisplay: Identifiable, Sendable {
    var id: CGDirectDisplayID
    var frame: CGRect
}

enum RecordingApplicationSelectionResolver {
    static func candidates(
        applications: [RecordingApplicationTarget],
        windows: [RecordingApplicationWindow],
        displays: [RecordingApplicationDisplay],
        excludedBundleIdentifier: String?
    ) -> [RecordingApplicationCandidate] {
        applications.compactMap { app in
            guard app.bundleIdentifier != excludedBundleIdentifier else { return nil }
            let frames = windows.filter { $0.processID == app.processID && $0.isOnScreen && $0.layer == 0 && !$0.frame.isEmpty }
            let ids = Set(displays.filter { display in
                frames.contains { $0.frame.intersects(display.frame) }
            }.map(\.id))
            guard !ids.isEmpty else { return nil }
            return RecordingApplicationCandidate(application: app, displayIDs: ids)
        }.sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
    }

    static func validate(_ selection: RecordingApplicationSelection, candidates: [RecordingApplicationCandidate]) -> Bool {
        !selection.applications.isEmpty && selection.applications.allSatisfy { selected in
            candidates.contains { $0.application.matches(selected) && $0.displayIDs.contains(selection.displayID) }
        }
    }
}

struct RecordingApplicationWindow: Sendable {
    var processID: Int32
    var isOnScreen: Bool
    var layer: Int
    var frame: CGRect
}

enum RecordingApplicationContent {
    static func target(_ app: SCRunningApplication) -> RecordingApplicationTarget {
        RecordingApplicationTarget(bundleIdentifier: app.bundleIdentifier, processID: app.processID,
                                   name: app.applicationName.isEmpty ? app.bundleIdentifier : app.applicationName)
    }

    static func candidates(in content: SCShareableContent) -> [RecordingApplicationCandidate] {
        RecordingApplicationSelectionResolver.candidates(
            applications: content.applications.map(target),
            windows: content.windows.compactMap { window in
                guard let app = window.owningApplication else { return nil }
                return RecordingApplicationWindow(processID: app.processID, isOnScreen: window.isOnScreen,
                                                  layer: window.windowLayer, frame: window.frame)
            },
            displays: content.displays.map { RecordingApplicationDisplay(id: $0.displayID, frame: $0.frame) },
            excludedBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func filter(selection: RecordingApplicationSelection, content: SCShareableContent, requireAll: Bool) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw RecordingError.captureTargetUnavailable
        }
        let applications = content.applications.filter { app in selection.applications.contains { $0.matches(target(app)) } }
        guard !applications.isEmpty, !requireAll || applications.count == selection.applications.count else {
            throw requireAll ? RecordingError.applicationUnavailable : RecordingError.captureApplicationsUnavailable
        }
        let filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        filter.includeMenuBar = false
        return filter
    }
}
