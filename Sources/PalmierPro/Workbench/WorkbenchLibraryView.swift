import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchLibraryView: View {
    @Bindable private var store = WorkbenchStore.shared

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Create")
                        .font(.system(size: 28, weight: .light))
                    Text("Transcribe, dub, and edit video.")
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

                if !recentItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent work")
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                        ForEach(recentItems.prefix(8)) { item in
                            Button {
                                item.open()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.icon)
                                        .foregroundStyle(item.tint)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .foregroundStyle(AppTheme.Text.primaryColor)
                                        Text(item.subtitle)
                                            .font(.system(size: AppTheme.FontSize.xs))
                                            .foregroundStyle(AppTheme.Text.mutedColor)
                                    }
                                    Spacer()
                                    Text(item.state.label)
                                        .font(.system(size: AppTheme.FontSize.xs))
                                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: AppTheme.FontSize.xs))
                                        .foregroundStyle(AppTheme.Text.mutedColor)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 58)
                                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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

    private var recentItems: [RecentWorkbenchItem] {
        store.sessions.map { session in
            RecentWorkbenchItem(
                id: "session-\(session.id)",
                title: session.title,
                subtitle: "\(session.source == .standaloneDub ? "Dub" : session.hasDub ? "Transcript + Dub" : "Transcript") · \(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))",
                icon: session.hasDub ? "waveform.and.mic" : "text.bubble",
                tint: session.hasDub ? .purple : .blue,
                state: session.state,
                modifiedAt: session.modifiedAt,
                open: { store.openSession(session.id) }
            )
        }
    }
}

private struct RecentWorkbenchItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let state: WorkbenchJobState
    let modifiedAt: Date
    let open: () -> Void
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
