import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RecentSessionsView: View {
    @Bindable private var store = WorkbenchStore.shared
    @State private var searchText = ""

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.sessions }
        return store.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query)
                || session.transcript?.text.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Recent sessions")
                            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                        Text("Every completed workflow opens in the same session workspace.")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer()
                    TextField("Search sessions", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AppTheme.Workbench.searchWidth)
                }

                if filteredSessions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No sessions yet" : "No matching sessions",
                        systemImage: "clock",
                        description: Text(searchText.isEmpty
                            ? "Transcribe media or create a dub to start a session."
                            : "Try a different session name or transcript phrase.")
                    )
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
                } else {
                    LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                        ForEach(filteredSessions) { session in
                            Button { store.openSession(session.id) } label: {
                                SessionListRow(session: session)
                            }
                            .buttonStyle(.plain)
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
                            }
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
    }
}

private struct SessionListRow: View {
    let session: WorkbenchSession

    var body: some View {
        HStack(spacing: AppTheme.Spacing.lgXl) {
            Image(systemName: session.hasDub ? "waveform.and.mic" : "text.bubble")
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(session.hasDub ? Color.purple : Color.blue)
                .frame(width: AppTheme.Workbench.sessionIconSize, height: AppTheme.Workbench.sessionIconSize)
                .background(
                    (session.hasDub ? Color.purple : Color.blue).opacity(AppTheme.Opacity.soft),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                )
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(session.title)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Text(sessionKind(session))
                    if let duration = session.duration {
                        Text(formatTime(duration))
                    }
                    Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            }
            Spacer()
            SessionStatusBadge(state: session.state)
            Image(systemName: "chevron.right")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(minHeight: AppTheme.Workbench.sessionHeaderMinHeight)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .contentShape(Rectangle())
    }

    private func sessionKind(_ session: WorkbenchSession) -> String {
        if session.source == .standaloneDub { return "Dub" }
        return session.hasDub ? "Transcript + Dub" : "Transcript"
    }
}

struct WorkbenchSessionDetailView: View {
    @Bindable private var store = WorkbenchStore.shared
    @State private var selectedTrack = SessionPlaybackTrack.original
    @State private var selectedTab = SessionDetailTab.transcript
    @State private var isRenamingTitle = false
    @State private var showTranslateSheet = false
    @State private var showDubOptionsSheet = false

    var body: some View {
        Group {
            if let session = store.selectedSession {
                sessionView(session)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a session from Recent.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.baseColor)
        .onChange(of: store.selectedSessionID) { _, _ in
            isRenamingTitle = false
        }
        .sheet(isPresented: $showTranslateSheet) {
            if let session = store.selectedSession,
               let transcriptionID = session.transcriptionID {
                SessionTranslateSheet(
                    sourceLanguage: session.transcript?.language,
                    onCancel: { showTranslateSheet = false },
                    onContinue: { targetLanguage in
                        store.updateTranscription(transcriptionID) { job in
                            job.targetLanguageCode = targetLanguage
                        }
                        showTranslateSheet = false
                        store.runTranslation(transcriptionID)
                    }
                )
            }
        }
        .sheet(isPresented: $showDubOptionsSheet) {
            if let session = store.selectedSession {
                SessionDubOptionsSheet(
                    session: session,
                    onCancel: { showDubOptionsSheet = false },
                    onManageVoices: {
                        showDubOptionsSheet = false
                        store.route = .voiceLibrary
                    },
                    onStart: { referenceVoiceID in
                        guard let transcriptionID = session.transcriptionID,
                              let dubID = store.createDub(for: transcriptionID) else {
                            showDubOptionsSheet = false
                            return
                        }
                        store.updateDub(dubID) { dub in
                            dub.referenceVoiceID = referenceVoiceID
                        }
                        showDubOptionsSheet = false
                    }
                )
            }
        }
    }

    private func sessionView(_ session: WorkbenchSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                sessionHeader(session)
                SessionMediaPlayer(
                    URL: selectedTrack == .dub ? session.outputURL : session.sourceURL,
                    track: selectedTrack,
                    allowsTrackSelection: session.sourceURL != nil && session.outputURL != nil,
                    onSelectTrack: { selectedTrack = $0 }
                )
                tabBar(session)
                sessionContent(session)
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) {
            if selectedTrack == .original,
               let sourceURL = session.sourceURL,
               sourceURL.isMovie {
                SessionFloatingVideo(URL: sourceURL)
                    .padding(AppTheme.Spacing.xl)
            }
        }
        .onAppear {
            selectedTrack = session.sourceURL == nil && session.outputURL != nil ? .dub : .original
            selectedTab = availableTabs(session).first ?? .transcript
        }
    }

    private func sessionHeader(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.smMd) {
                    if isRenamingTitle {
                        InlineRenameField(
                            originalName: session.title,
                            placeholder: "Session title",
                            font: .system(
                                size: AppTheme.FontSize.title2,
                                weight: AppTheme.FontWeight.semibold
                            ),
                            onCommit: { title in
                                store.renameSession(session.id, to: title)
                                isRenamingTitle = false
                            },
                            onCancel: { isRenamingTitle = false }
                        )
                    } else {
                        Text(session.title)
                            .font(.system(
                                size: AppTheme.FontSize.title2,
                                weight: AppTheme.FontWeight.semibold
                            ))
                            .lineLimit(1)
                        Button {
                            isRenamingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .help("Rename session")
                    }
                }
                HStack(spacing: AppTheme.Spacing.md) {
                    Label(session.modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    if let duration = session.duration {
                        Label(formatTime(duration), systemImage: "clock.arrow.circlepath")
                    }
                    Label("Stored on this Mac", systemImage: "lock.shield")
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            SessionStatusBadge(state: session.state)
            if let dubID = session.dubID {
                revisionPicker(dubID: dubID)
            }
            Button {
                if session.transcriptionID != nil {
                    showDubOptionsSheet = true
                } else {
                    openWorkflow(session)
                }
            } label: {
                Label(session.hasDub ? "Re-dub" : "Create dub", systemImage: "waveform.and.mic")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(minHeight: AppTheme.Workbench.sessionHeaderMinHeight)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    @ViewBuilder
    private func revisionPicker(dubID: UUID) -> some View {
        if let dub = store.dubs.first(where: { $0.id == dubID }),
           let revisions = dub.revisions,
           revisions.count > 1 {
            Picker("Revision", selection: revisionBinding(dubID)) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { offset, revision in
                    Text("Version \(offset + 1) · \(revision.createdAt.formatted(date: .omitted, time: .shortened))")
                        .tag(revision.id as UUID?)
                }
            }
            .labelsHidden()
            .frame(width: AppTheme.Workbench.revisionPickerWidth)
        }
    }

    private func tabBar(_ session: WorkbenchSession) -> some View {
        HStack(spacing: AppTheme.Spacing.xlXxl) {
            ForEach(availableTabs(session)) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        Text(tab.title)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                        Rectangle()
                            .fill(selectedTab == tab ? AppTheme.Accent.primary : Color.clear)
                            .frame(height: AppTheme.BorderWidth.thick)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if session.transcriptionID != nil {
                Button {
                    showTranslateSheet = true
                } label: {
                    Label("Translate", systemImage: "character.book.closed")
                }
                .buttonStyle(.bordered)
            }
            if let URL = selectedTrack == .dub ? session.outputURL : session.sourceURL {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL]) }
                    .buttonStyle(.bordered)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.thin)
        }
    }

    @ViewBuilder
    private func sessionContent(_ session: WorkbenchSession) -> some View {
        switch selectedTab {
        case .transcript:
            let segments = (transcriptResult(for: session)?.aggregatingSegments().segments ?? []).map(SessionTextSegment.init)
            SessionSegmentList(segments: segments, emptyText: "No timed transcript is available for this track.")
        case .subtitles:
            let track = selectedTrack == .dub
                ? session.dubSubtitleTrack
                : session.subtitleTrack
            SessionSegmentList(
                segments: (track?.cues ?? []).map(SessionTextSegment.init),
                emptyText: "No subtitle track is available."
            )
        case .translation:
            SessionSegmentList(
                segments: (session.translationTrack?.cues ?? []).map(SessionTextSegment.init),
                emptyText: "No translated subtitle track is available."
            )
        }
    }

    private func transcriptResult(for session: WorkbenchSession) -> TranscriptionResult? {
        if selectedTrack == .dub {
            if let transcript = session.dubTranscript { return transcript }
            guard !session.dubSegments.isEmpty else { return nil }
            return TranscriptionResult(
                text: TranscriptSegmenter.joinedText(session.dubSegments.map(\.text)),
                language: nil,
                words: [],
                segments: session.dubSegments.map {
                    TranscriptionSegment(
                        text: $0.text,
                        start: $0.start,
                        end: $0.end,
                        speaker: $0.speaker
                    )
                }
            )
        }

        // The transcript tab is the aggregated, corrected view. The subtitle
        // tab intentionally keeps each cue boundary.
        return session.subtitleTrack?
            .asTranscriptionResult(preservingWords: session.transcript?.words ?? [])
            ?? session.transcript
    }

    private func availableTabs(_ session: WorkbenchSession) -> [SessionDetailTab] {
        var tabs: [SessionDetailTab] = []
        if session.transcript != nil || session.dubTranscript != nil || !session.dubSegments.isEmpty {
            tabs.append(.transcript)
        }
        if session.subtitleTrack != nil || session.dubSubtitleTrack != nil { tabs.append(.subtitles) }
        if session.translationTrack != nil { tabs.append(.translation) }
        return tabs.isEmpty ? [.transcript] : tabs
    }

    private func openWorkflow(_ session: WorkbenchSession) {
        if let transcriptionID = session.transcriptionID {
            _ = store.createDub(for: transcriptionID)
        } else if let dubID = session.dubID {
            store.selectedDubID = dubID
            store.route = .dub
        }
    }

    private func revisionBinding(_ dubID: UUID) -> Binding<UUID?> {
        Binding(
            get: { store.dubs.first(where: { $0.id == dubID })?.activeRevisionID },
            set: { revisionID in
                guard let revisionID else { return }
                store.activateDubRevision(revisionID, forDub: dubID)
            }
        )
    }
}

private enum SessionPlaybackTrack: String, CaseIterable, Identifiable {
    case original
    case dub

    var id: String { rawValue }
    var title: String { self == .original ? "Original" : "Dub" }
}

private enum SessionDetailTab: String, Identifiable {
    case transcript
    case subtitles
    case translation

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct SessionTextSegment: Identifiable {
    let id: String
    let text: String
    let start: Double
    let end: Double
    let speaker: String?

    init(_ segment: TranscriptionSegment) {
        id = "transcript-\(segment.start)-\(segment.end)-\(segment.text.hashValue)"
        text = segment.text
        start = segment.start
        end = segment.end
        speaker = segment.speaker
    }

    init(_ cue: SubtitleCue) {
        id = "subtitle-\(cue.id)"
        text = cue.text
        start = cue.start
        end = cue.end
        speaker = cue.speaker
    }

    init(_ segment: DubRenderedSegment) {
        id = "dub-\(segment.index)"
        text = segment.text
        start = segment.start
        end = segment.end
        speaker = segment.speaker
    }
}

private struct SessionSegmentList: View {
    let segments: [SessionTextSegment]
    let emptyText: String

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView("No segments", systemImage: "text.alignleft", description: Text(emptyText))
                .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
        } else {
            LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                ForEach(segments) { segment in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
                        Image(systemName: "play.fill")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Accent.link)
                            .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                            .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Circle())
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Text("\(formatTime(segment.start)) — \(formatTime(segment.end))")
                                if let speaker = segment.speaker, !speaker.isEmpty {
                                    Text(speaker)
                                }
                            }
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            Text(segment.text)
                                .font(.system(size: AppTheme.FontSize.mdLg))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(AppTheme.Spacing.lgXl)
                    .frame(minHeight: AppTheme.Workbench.transcriptCardMinHeight, alignment: .topLeading)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    }
                }
            }
        }
    }
}

private struct SessionDubOptionsSheet: View {
    let session: WorkbenchSession
    let onCancel: () -> Void
    let onManageVoices: () -> Void
    let onStart: (UUID?) -> Void
    @State private var referenceVoiceID: UUID?

    private var languageCode: String {
        session.transcript?.language
            ?? session.subtitleTrack?.language
            ?? "auto"
    }

    private var speakers: [String] {
        let values = (session.transcript?.segments.compactMap(\.speaker) ?? [])
            + (session.subtitleTrack?.cues.compactMap(\.speaker) ?? [])
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Preview recommended voices")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text("Choose a session voice before opening the dub editor. Speaker and segment overrides remain available there.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(speakers.isEmpty ? "SESSION VOICE" : "SESSION VOICE · \(speakers.count) SPEAKERS")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                VoiceReferenceSelectionPanel(
                    selection: $referenceVoiceID,
                    languageCode: languageCode,
                    onManage: onManageVoices
                )
                if !speakers.isEmpty {
                    Text("Automatic voice applies to all speakers unless you assign a speaker-specific voice in the dub editor.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start dubbing") {
                    onStart(referenceVoiceID)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 620)
    }
}

private struct SessionTranslateSheet: View {
    let sourceLanguage: String?
    let onCancel: () -> Void
    let onContinue: (String) -> Void
    @State private var targetLanguage = ""

    private var options: [WorkbenchTranscriptionLanguage] {
        WorkbenchTranscriptionLanguage.allCases.filter { $0.languageCode != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Translate session")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text("Select a target language. Subtitle cleanup and timing alignment are preserved.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            GroupBox("Target language") {
                Picker("Target language", selection: $targetLanguage) {
                    Text("Choose a language").tag("")
                    Divider()
                    ForEach(options) { option in
                        Text(option.label).tag(option.languageCode ?? "")
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    onContinue(targetLanguage)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(targetLanguage.isEmpty || targetLanguage == (sourceLanguage ?? ""))
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 520)
    }
}

private struct SessionMediaPlayer: View {
    let URL: URL?
    let track: SessionPlaybackTrack
    let allowsTrackSelection: Bool
    let onSelectTrack: (SessionPlaybackTrack) -> Void

    @State private var player: AVPlayer?
    @State private var peaks: [Float] = []
    @State private var isPlaying = false
    @State private var duration = 0.0

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                if allowsTrackSelection {
                    Picker("Track", selection: Binding(get: { track }, set: { value in onSelectTrack(value) })) {
                        ForEach(SessionPlaybackTrack.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text(track.title)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                }
                Spacer()
                Text(URL?.lastPathComponent ?? "Media unavailable")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
            }

            SwiftUI.TimelineView(
                .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
            ) { _ in
                let currentTime = player?.currentTime().seconds.finiteOrZero ?? 0
                VStack(spacing: AppTheme.Spacing.smMd) {
                    SessionWaveform(peaks: peaks, progress: duration > 0 ? currentTime / duration : 0)
                        .frame(height: AppTheme.Workbench.waveformHeight)
                    HStack(spacing: AppTheme.Spacing.md) {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(player == nil)

                        Slider(
                            value: Binding(
                                get: { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 },
                                set: { seek(to: $0) }
                            ),
                            in: 0...1
                        )
                        .disabled(player == nil || duration <= 0)
                        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .task(id: URL) { await load() }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func load() async {
        player?.pause()
        isPlaying = false
        peaks = []
        duration = 0
        guard let URL else {
            player = nil
            return
        }
        let nextPlayer = AVPlayer(url: URL)
        player = nextPlayer
        duration = (try? await nextPlayer.currentItem?.asset.load(.duration).seconds)?.finiteOrZero ?? 0
        peaks = (try? await WaveformExtractor.peakEnvelope(from: URL)) ?? []
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, player.currentTime().seconds >= duration - AppTheme.Workbench.playerEndTolerance {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func seek(to progress: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: progress * duration, preferredTimescale: AppTheme.Workbench.playerTimescale))
    }
}

private struct SessionWaveform: View {
    let peaks: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let sampleCount = min(peaks.count, max(1, Int(proxy.size.width / AppTheme.Workbench.waveformBarStep)))
            let sampled = peaks.downsampled(to: sampleCount)
            HStack(alignment: .center, spacing: AppTheme.Workbench.waveformBarSpacing) {
                ForEach(Array(sampled.enumerated()), id: \.offset) { index, sample in
                    let loudness = max(AppTheme.Workbench.waveformMinimumLoudness, 1 - CGFloat(sample))
                    Capsule()
                        .fill(Double(index) / Double(max(1, sampled.count)) <= progress
                            ? AppTheme.Accent.primary
                            : AppTheme.Text.mutedColor)
                        .frame(maxWidth: AppTheme.Workbench.waveformBarWidth)
                        .frame(height: max(AppTheme.Workbench.waveformMinimumBarHeight, proxy.size.height * loudness))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("Audio waveform")
    }
}

private struct SessionFloatingVideo: View {
    let URL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Source preview", systemImage: "play.rectangle")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(height: AppTheme.Workbench.floatingPlayerHeaderHeight)
            VideoPlayer(player: player)
        }
        .frame(width: AppTheme.Workbench.floatingPlayerWidth, height: AppTheme.Workbench.floatingPlayerHeight)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.lg)
        .onAppear { player = AVPlayer(url: URL) }
        .onDisappear { player?.pause() }
    }
}

private struct SessionStatusBadge: View {
    let state: WorkbenchJobState

    var body: some View {
        Label(state.label, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(color)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(color.opacity(AppTheme.Opacity.soft), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .completed: AppTheme.Status.successColor
        case .failed: AppTheme.Status.errorColor
        case .running, .cancelling: AppTheme.Status.warningColor
        case .ready, .cancelled: AppTheme.Text.tertiaryColor
        }
    }

    private var systemImage: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .running, .cancelling: "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "circle"
        case .cancelled: "xmark.circle"
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remaining = total % 60
    return hours > 0
        ? String(format: "%02d:%02d:%02d", hours, minutes, remaining)
        : String(format: "%02d:%02d", minutes, remaining)
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

private extension URL {
    var isMovie: Bool {
        UTType(filenameExtension: pathExtension)?.conforms(to: .movie) == true
    }
}

private extension Array where Element == Float {
    func downsampled(to count: Int) -> [Float] {
        guard count > 0, self.count > count else { return self }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        let sourceCount: Int = self.count
        let lastIndex: Int = sourceCount - 1
        for index in 0..<count {
            let scaledIndex: Int = index * sourceCount
            let proportionalIndex: Int = scaledIndex / count
            let sourceIndex: Int = Swift.min(lastIndex, proportionalIndex)
            samples.append(self[sourceIndex])
        }
        return samples
    }
}
