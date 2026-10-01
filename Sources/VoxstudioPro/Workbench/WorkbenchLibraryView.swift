import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchLibraryView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var voiceInputShortcut = VoiceInputShortcutPreferences.shared
    @State private var sessionPendingDeletion: WorkbenchSession?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: AppTheme.Spacing.lg)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Create"))
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    Text(L10n.string("Choose a task to turn media into text, voice, or a finished video."))
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    actionCard(
                        title: L10n.string("Transcribe media"),
                        detail: L10n.string("Turn audio or video into an editable transcript, translation, and captions."),
                        icon: "text.bubble.fill",
                        tint: .blue
                    ) {
                        Task {
                            let urls = await WorkbenchFilePicker.pickMediaFiles()
                            if !urls.isEmpty {
                                store.stageMediaImport(urls)
                            }
                        }
                    }
                    actionCard(
                        title: L10n.string("Record and transcribe"),
                        detail: L10n.string("Capture your voice or screen, then turn it into an editable transcript."),
                        icon: "record.circle.fill",
                        tint: .red
                    ) {
                        store.showRecordImport()
                    }
                    actionCard(
                        title: L10n.string("Import online video"),
                        detail: L10n.string("Bring audio from a public online video into a task."),
                        icon: "play.rectangle.fill",
                        tint: .orange
                    ) {
                        store.showNetVideoImport()
                    }
                    actionCard(
                        title: L10n.string("Create a voiceover"),
                        detail: L10n.string("Turn a script into a voiceover with a selected reference voice."),
                        icon: "waveform.and.mic",
                        tint: .purple
                    ) {
                        Task { @MainActor in
                            _ = await store.addDubAfterAccess()
                        }
                    }
                    actionCard(
                        title: L10n.string("Edit a video"),
                        detail: L10n.string("Arrange video, audio, images, and captions into a finished project."),
                        icon: "timeline.selection",
                        tint: .orange
                    ) {
                        store.route = .videoEditor
                    }
                    actionCard(
                        title: L10n.string("Dictation"),
                        detail: String(
                            format: L10n.string("Press %@ to speak into any app."),
                            voiceInputShortcut.option.label
                        ),
                        icon: "mic.fill",
                        tint: .teal
                    ) {
                        VoiceInputCoordinator.shared.present()
                    }
                    actionCard(
                        title: L10n.string("Meeting Recorder"),
                        detail: String(
                            format: L10n.string("Send a notetaker to Meet, Teams, or Zoom. Requires a %@ plan or higher."),
                            AccountFeature.meetBot.minimumPlan.localizedUpgradeLabel
                        ),
                        icon: "calendar.badge.clock",
                        tint: AppTheme.Accent.meetingBotBadge
                    ) {
                        store.route = .meetBot
                    }
                }

                if !store.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        Text(L10n.string("Recent tasks"))
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                        LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                            ForEach(store.sessions.prefix(8)) { session in
                                SessionListRow(
                                    session: session,
                                    onOpen: { store.openSession(session.id) },
                                    onDelete: { sessionPendingDeletion = session },
                                    allowsDelete: true
                                )
                                .contextMenu {
                                    if let sourceURL = session.sourceURL {
                                        Button(L10n.string("Reveal source in Finder")) {
                                            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                        }
                                    }
                                    if let outputURL = session.outputURL {
                                        Button(L10n.string("Reveal dub in Finder")) {
                                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                        }
                                    }
                                    Divider()
                                    Button(L10n.string("Delete"), role: .destructive) {
                                        sessionPendingDeletion = session
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("Video projects"))
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                    MyProjectsSection()
                        .frame(minHeight: 210)
                        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                }
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: AppTheme.Workbench.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.baseColor)
        .alert(item: $sessionPendingDeletion) { session in
            Alert(
                title: Text(L10n.string("Delete session?")),
                message: Text(L10n.format("\"%@\" and its saved workflow data will be removed.", session.title)),
                primaryButton: .destructive(Text(L10n.string("Delete"))) {
                    store.deleteSession(session.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func actionCard(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.title1, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .padding(18)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum WorkbenchFilePicker {
    static let transcribableContentTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    nonisolated static func isProjectPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == Project.fileExtension || ext == Project.legacyFileExtension
    }

    nonisolated static func isTranscribableMedia(_ url: URL, contentType: UTType? = nil) -> Bool {
        if isProjectPackage(url) { return false }
        if let contentType {
            if isTranscribable(contentType) { return true }
            if contentType.conforms(to: .image)
                || contentType.conforms(to: .text)
                || contentType.conforms(to: .pdf) {
                return false
            }
        }
        let ext = url.pathExtension.lowercased()
        switch ClipType(fileExtension: ext) {
        case .audio, .video: return true
        default: break
        }
        if extraMediaExtensions.contains(ext) { return true }
        guard let type = contentType ?? UTType(filenameExtension: ext) else { return false }
        return isTranscribable(type)
    }

    nonisolated private static func isTranscribable(_ type: UTType) -> Bool {
        type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    nonisolated private static let extraMediaExtensions: Set<String> = [
        "mkv", "webm", "avi", "ogg", "opus",
    ]

    @MainActor
    static func pickMedia() async -> URL? {
        await pickMediaFiles().first
    }

    @MainActor
    static func pickMediaFiles() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose audio or video")
        panel.message = L10n.string("Select one or more files. Processing runs one file at a time.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = transcribableContentTypes
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
        }
    }

    @MainActor
    static func pickAudio(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.string(key: title)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}
