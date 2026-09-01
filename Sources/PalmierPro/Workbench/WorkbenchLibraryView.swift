import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchLibraryView: View {
    @Bindable private var store = WorkbenchStore.shared
    @State private var sessionPendingDeletion: WorkbenchSession?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Create")
                        .font(.system(size: 28, weight: .light))
                    Text("Transcribe, record, dub, and edit video.")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    actionCard(
                        title: "Transcribe media",
                        detail: "Word timestamps · speaker labels · editor captions",
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
                        title: "Record",
                        detail: "Mic · display · window · region · then transcribe",
                        icon: "record.circle.fill",
                        tint: .red
                    ) {
                        store.showRecordImport()
                    }
                    actionCard(
                        title: "Net video",
                        detail: "Paste a YouTube link · audio only · then transcribe",
                        icon: "play.rectangle.fill",
                        tint: .orange
                    ) {
                        store.showNetVideoImport()
                    }
                    actionCard(
                        title: "Create a dub",
                        detail: "Qwen3-TTS · voice clone · local WAV",
                        icon: "waveform.and.mic",
                        tint: .purple
                    ) {
                        store.addDub()
                    }
                    actionCard(
                        title: "Edit a video",
                        detail: "Full timeline editor · local media fallback",
                        icon: "timeline.selection",
                        tint: .orange
                    ) {
                        store.route = .videoEditor
                    }
                }

                if !store.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        Text("Recent work")
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
                                        Button("Reveal source in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                        }
                                    }
                                    if let outputURL = session.outputURL {
                                        Button("Reveal dub in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                        }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        sessionPendingDeletion = session
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Video projects")
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                    MyProjectsSection()
                        .frame(minHeight: 210)
                        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
        .alert(item: $sessionPendingDeletion) { session in
            Alert(
                title: Text("Delete session?"),
                message: Text("\"\(session.title)\" and its saved workflow data will be removed."),
                primaryButton: .destructive(Text("Delete")) {
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
                    .font(.system(size: 22, weight: .medium))
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
    @MainActor
    static func pickMedia() async -> URL? {
        await pickMediaFiles().first
    }

    @MainActor
    static func pickMediaFiles() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose audio or video"
        panel.message = "Select one or more files. Processing runs one file at a time."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
        }
    }

    @MainActor
    static func pickAudio(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}
