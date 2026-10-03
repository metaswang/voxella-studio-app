import AppKit
import UniformTypeIdentifiers

struct ExternalOpenPartition: Equatable, Sendable {
    var sessions: [UUID] = []
    var projects: [URL] = []
    var media: [URL] = []
    var unsupported: [URL] = []
}

enum ExternalOpenClassifier {
    nonisolated static func partition(_ urls: [URL]) -> ExternalOpenPartition {
        var partition = ExternalOpenPartition()
        var seen = Set<String>()
        for url in urls {
            append(url, into: &partition, seen: &seen, expandDirectories: true)
        }
        return partition
    }

    nonisolated private static func append(
        _ url: URL,
        into partition: inout ExternalOpenPartition,
        seen: inout Set<String>,
        expandDirectories: Bool
    ) {
        if let scheme = url.scheme?.lowercased(),
           scheme == "voxella-studio" || scheme == "voxstudio" {
            appendCustomScheme(url, into: &partition, seen: &seen)
            return
        }
        guard url.isFileURL else { return }

        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard seen.insert(resolved.path).inserted else { return }

        if WorkbenchFilePicker.isProjectPackage(resolved) {
            partition.projects.append(resolved)
            return
        }

        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        if values?.isPackage == true {
            partition.unsupported.append(resolved)
            return
        }
        if values?.isDirectory == true {
            guard expandDirectories else { return }
            appendDirectoryContents(resolved, into: &partition, seen: &seen)
            return
        }

        if WorkbenchFilePicker.isTranscribableMedia(resolved, contentType: values?.contentType) {
            partition.media.append(resolved)
        } else {
            partition.unsupported.append(resolved)
        }
    }

    nonisolated private static func appendCustomScheme(
        _ url: URL,
        into partition: inout ExternalOpenPartition,
        seen: inout Set<String>
    ) {
        switch url.host?.lowercased() {
        case "oauth":
            return
        case "sessions":
            if let id = sessionID(from: url), seen.insert("session:\(id.uuidString)").inserted {
                partition.sessions.append(id)
            }
        case "transcribe":
            for fileURL in mediaFileURLs(fromTranscribeURL: url) {
                append(fileURL, into: &partition, seen: &seen, expandDirectories: true)
            }
        default:
            return
        }
    }

    nonisolated static func sessionID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "voxstudio" || scheme == "voxella-studio",
              components.host?.lowercased() == "sessions",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    nonisolated static func mediaFileURLs(fromTranscribeURL url: URL) -> [URL] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.compactMap { item in
            guard item.name == "file" || item.name == "url", let value = item.value, !value.isEmpty else {
                return nil
            }
            if let parsed = URL(string: value), parsed.isFileURL {
                return parsed
            }
            if value.hasPrefix("/") {
                return URL(fileURLWithPath: value)
            }
            return nil
        }
    }

    nonisolated private static func appendDirectoryContents(
        _ directory: URL,
        into partition: inout ExternalOpenPartition,
        seen: inout Set<String>
    ) {
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey],
                options: [.skipsHiddenFiles]
            )
            for child in children {
                append(child, into: &partition, seen: &seen, expandDirectories: false)
            }
        } catch {
            partition.unsupported.append(directory)
        }
    }
}

enum ExternalOpenPasteboard {
    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    nonisolated static func fileURL(fromItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL { return url }
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        }
        return nil
    }
}

@MainActor
enum ExternalOpenHandler {
    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await process(urls) }
    }

    static func open(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            urls.reserveCapacity(fileProviders.count)
            for provider in fileProviders {
                if let url = await fileURL(from: provider) {
                    urls.append(url)
                }
            }
            open(urls)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: ExternalOpenPasteboard.fileURL(fromItem: item))
            }
        }
    }

    private static func process(_ urls: [URL]) async {
        let snapshot = urls
        let partition = await Task.detached(priority: .userInitiated) {
            ExternalOpenClassifier.partition(snapshot)
        }.value
        await apply(partition)
    }

    private static func apply(_ partition: ExternalOpenPartition) async {
        Log.app.notice(
            "external open sessions=\(partition.sessions.count) media=\(partition.media.count) projects=\(partition.projects.count) unsupported=\(partition.unsupported.count)"
        )
        if let sessionID = partition.sessions.first {
            await presentSession(sessionID)
            return
        }
        if !partition.media.isEmpty {
            presentTranscription(for: partition.media)
            if !partition.unsupported.isEmpty {
                WorkbenchTipCenter.shared.show(
                    skippedUnsupportedMessage(partition.unsupported.count),
                    kind: .info,
                    id: "external-open.skipped-unsupported"
                )
            }
            return
        }
        if let project = partition.projects.first {
            NSApp.activate(ignoringOtherApps: true)
            AppState.shared.openProject(at: project)
            return
        }
        if !partition.unsupported.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            AppState.shared.showHome()
            WorkbenchTipCenter.shared.show(
                "VoxStudio opens audio and video files for transcription.",
                kind: .error,
                id: "external-open.unsupported"
            )
        }
    }

    private static func presentSession(_ id: UUID) async {
        let store = WorkbenchStore.shared
        // A session link can be the LaunchServices request that starts the app.
        // Wait for the saved library before deciding whether its target exists.
        for _ in 0..<100 {
            if !store.isHydrating { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: AccountService.shared.isSignedIn)
        let visible = store.sessions.contains { session in
            session.id == id && allowed.contains(KnowledgeSourceOrigin.resolve(
                isCloudStorage: session.storage == .cloud,
                hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
            ))
        }
        if !store.isHydrating && visible {
            store.openSession(id)
        }
        AppState.shared.showHome()
        HomeWindowController.shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if store.isHydrating || !visible {
            WorkbenchTipCenter.shared.show(
                store.isHydrating
                    ? "The session library is still loading. Open the session link again shortly."
                    : "This session is no longer available in VoxStudio.",
                kind: .error,
                id: "external-open.session-unavailable"
            )
        }
    }

    private static func presentTranscription(for urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        HomeWindowController.shared.showWindow(nil)
        HomeWindowController.shared.window?.makeKeyAndOrderFront(nil)
        WorkbenchStore.shared.stageMediaImport(urls)
    }

    private static func skippedUnsupportedMessage(_ count: Int) -> String {
        count == 1
            ? "Skipped 1 item that is not audio or video."
            : "Skipped \(count) items that are not audio or video."
    }
}
