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
    /// `nil` means Original; otherwise a translation language code.
    @State private var transcriptLanguageCode: String?
    @State private var subtitleLanguageCode: String?
    @State private var isRenamingTitle = false
    @State private var showTranslateSheet = false
    @State private var showDubOptionsSheet = false
    @State private var showTemplateLoginAlert = false
    @State private var seekSeconds: Double?

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
        .alert("My Template", isPresented: $showTemplateLoginAlert) {
            Button("Open voxstudio.me") {
                if let url = URL(string: "https://voxstudio.me") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in at voxstudio.me to use custom summary templates. Local Studio does not support custom templates yet.")
        }
    }

    @ViewBuilder
    private func sessionView(_ session: WorkbenchSession) -> some View {
        let mediaURL = selectedTrack == .dub ? session.outputURL : session.sourceURL
        let hasVideo = mediaURL?.isMovie == true

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            sessionHeader(session)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SessionMediaPlayer(
                        URL: mediaURL,
                        track: selectedTrack,
                        allowsTrackSelection: session.sourceURL != nil && session.outputURL != nil,
                        showsFilename: false,
                        prefersVideoCanvas: hasVideo,
                        subtitleTrack: hasVideo
                            ? (selectedTrack == .dub
                                ? session.dubSubtitleTrack
                                : session.subtitleTrack)
                            : nil,
                        translationTracks: hasVideo ? session.translationTracks : [],
                        seekSeconds: $seekSeconds,
                        onSelectTrack: { selectedTrack = $0 }
                    )
                    .layoutPriority(1)
                    SessionSummaryPanel(
                        session: session,
                        onOpenTemplate: {
                            presentTemplateLoginPrompt()
                        },
                        onRegenerate: {
                            guard let transcriptionID = session.transcriptionID else { return }
                            store.regenerateSummary(forTranscription: transcriptionID)
                        }
                    )
                    .frame(maxHeight: hasVideo ? AppTheme.Workbench.emptyStateMinHeight : .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.Background.baseColor)

                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(width: AppTheme.BorderWidth.thin)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    tabBar(session)
                        .padding(.horizontal, AppTheme.Spacing.xl)
                        .padding(.top, AppTheme.Spacing.lg)
                    ScrollView {
                        sessionContent(session)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.bottom, AppTheme.Spacing.xl)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.Background.baseColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
        .onAppear {
            selectedTrack = session.sourceURL == nil && session.outputURL != nil ? .dub : .original
            selectedTab = availableTabs(session).first ?? .transcript
            syncLanguageSelections(session)
        }
        .onChange(of: session.id) { _, _ in
            syncLanguageSelections(session)
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
                    if let duration = session.duration {
                        Label(formatTime(duration), systemImage: "clock")
                    }
                    Label(session.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    if let filename = session.originalFilename {
                        Label(filename, systemImage: "doc")
                            .lineLimit(1)
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
                compositeTabButton(tab, session: session)
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
    private func compositeTabButton(_ tab: SessionDetailTab, session: WorkbenchSession) -> some View {
        let isActive = selectedTab == tab
        let languageCode = tab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
        let hasTranslations = !session.translationTracks.isEmpty

        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                }
                .buttonStyle(.plain)

                if hasTranslations {
                    Menu {
                        Button("Original") {
                            selectedTab = tab
                            setLanguage(nil, for: tab, session: session)
                        }
                        Divider()
                        ForEach(session.translationTracks) { track in
                            Button {
                                selectedTab = tab
                                setLanguage(track.languageCode, for: tab, session: session)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(track.displayLanguageLabel)
                                        Text("\(track.track.cues.count) cues")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if languageCode?.caseInsensitiveCompare(track.languageCode) == .orderedSame {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            if let languageCode {
                                Text(WorkbenchLanguageLabel.compact(languageCode))
                                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                                    .foregroundStyle(AppTheme.Accent.primary)
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)

            Rectangle()
                .fill(isActive ? AppTheme.Accent.primary : Color.clear)
                .frame(height: AppTheme.BorderWidth.thick)
        }
    }

    @ViewBuilder
    private func sessionContent(_ session: WorkbenchSession) -> some View {
        let scope = cueScope(for: session)
        let cues = editableCues(for: session, scope: scope)
        SessionSegmentEditor(
            sessionID: session.id,
            scope: scope,
            cues: cues,
            speakerLabels: speakerLabels(for: session, cues: cues),
            emptyText: selectedTab == .transcript
                ? "No timed transcript is available for this track."
                : "No subtitle track is available.",
            onSeek: { seconds in
                seekSeconds = seconds
            }
        )
    }

    private func cueScope(for session: WorkbenchSession) -> WorkbenchStore.SessionCueScope {
        if selectedTrack == .dub { return .dub }
        let languageCode = selectedTab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
        if let languageCode { return .translation(languageCode) }
        return .source
    }

    private func editableCues(
        for session: WorkbenchSession,
        scope: WorkbenchStore.SessionCueScope
    ) -> [SubtitleCue] {
        switch scope {
        case .dub:
            if let cues = session.dubSubtitleTrack?.cues, !cues.isEmpty {
                return cues
            }
            return session.dubSegments.enumerated().map { index, segment in
                SubtitleCue(
                    id: index,
                    sourceIDs: [segment.sourceSubtitleID ?? segment.index],
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker
                )
            }
        case .translation(let languageCode):
            return session.translationTracks.first(where: {
                $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
            })?.track.cues ?? []
        case .source:
            if let cues = session.subtitleTrack?.cues, !cues.isEmpty {
                return cues
            }
            if let transcript = session.transcript {
                return SubtitleTrack.fromTranscript(transcript).cues
            }
            return []
        }
    }

    private func speakerLabels(for session: WorkbenchSession, cues: [SubtitleCue]) -> [String] {
        if let transcriptionID = session.transcriptionID,
           let job = store.transcriptions.first(where: { $0.id == transcriptionID }) {
            let labels = job.speakerLabels
            if !labels.isEmpty { return labels }
        }
        var seen = Set<String>()
        return cues.compactMap { cue in
            let normalized = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func availableTabs(_ session: WorkbenchSession) -> [SessionDetailTab] {
        var tabs: [SessionDetailTab] = []
        if session.transcript != nil || session.dubTranscript != nil || !session.dubSegments.isEmpty
            || session.subtitleTrack != nil {
            tabs.append(.transcript)
        }
        if session.subtitleTrack != nil || session.dubSubtitleTrack != nil
            || !session.translationTracks.isEmpty {
            tabs.append(.subtitles)
        }
        return tabs.isEmpty ? [.transcript] : tabs
    }

    private func setLanguage(_ code: String?, for tab: SessionDetailTab, session: WorkbenchSession) {
        switch tab {
        case .transcript:
            transcriptLanguageCode = code
        case .subtitles:
            subtitleLanguageCode = code
        }
        if let code, let transcriptionID = session.transcriptionID {
            store.selectTranslationLanguage(code, forTranscription: transcriptionID)
        }
    }

    private func syncLanguageSelections(_ session: WorkbenchSession) {
        let selected = session.selectedTranslationLanguageCode
        if let selected,
           session.translationTracks.contains(where: {
               $0.languageCode.caseInsensitiveCompare(selected) == .orderedSame
           }) {
            transcriptLanguageCode = selected
            subtitleLanguageCode = selected
        } else {
            transcriptLanguageCode = nil
            subtitleLanguageCode = nil
        }
    }

    private func presentTemplateLoginPrompt() {
        // Temporarily shield the template picker sheet; require voxstudio.me login messaging only.
        showTemplateLoginAlert = true
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

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    var showsFilename = true
    var prefersVideoCanvas = false
    var subtitleTrack: SubtitleTrack? = nil
    var translationTracks: [WorkbenchTranslationTrack] = []
    @Binding var seekSeconds: Double?
    let onSelectTrack: (SessionPlaybackTrack) -> Void

    @State private var player: AVPlayer?
    @State private var peaks: [Float] = []
    @State private var isPlaying = false
    @State private var duration = 0.0
    @State private var playbackRate = 1.0
    @State private var subtitleMode: SessionSubtitleDisplayMode = .original
    @State private var playerViewRef: AVPlayerView?

    private var showsVideoCanvas: Bool {
        prefersVideoCanvas || URL?.isMovie == true
    }

    private var activeSubtitleCues: [SubtitleCue] {
        switch subtitleMode {
        case .off:
            return []
        case .original:
            return subtitleTrack?.cues ?? []
        case .translation(let code):
            return translationTracks.first(where: {
                $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
            })?.track.cues ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if allowsTrackSelection {
                HStack {
                    Picker("Track", selection: Binding(get: { track }, set: { value in onSelectTrack(value) })) {
                        ForEach(SessionPlaybackTrack.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    if showsFilename {
                        Text(URL?.lastPathComponent ?? "Media unavailable")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.top, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.sm)
            }

            if showsVideoCanvas {
                videoCanvas
            } else {
                audioCanvas
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .task(id: URL) { await load() }
        .onChange(of: playbackRate) { _, rate in
            player?.rate = isPlaying ? Float(rate) : 0
            player?.defaultRate = Float(rate)
        }
        .onChange(of: seekSeconds) { _, seconds in
            guard let seconds else { return }
            seekAbsolute(to: seconds)
            seekSeconds = nil
        }
        .onDisappear { player?.pause() }
    }

    private var videoCanvas: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = player?.currentTime().seconds.finiteOrZero ?? 0
            let cueText = activeSubtitleText(at: currentTime)
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.black
                    if let player {
                        SessionAVPlayerRepresentable(
                            player: player,
                            onViewReady: { playerViewRef = $0 }
                        )
                    } else if URL != nil {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Text("Media unavailable")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }

                    if let cueText {
                        Text(cueText)
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.vertical, AppTheme.Spacing.smMd)
                            .background(Color.black.opacity(AppTheme.Opacity.medium), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.bottom, AppTheme.Spacing.xl)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight: AppTheme.Workbench.sessionVideoMinHeight,
                    idealHeight: AppTheme.Workbench.sessionVideoIdealHeight
                )
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                videoControls(currentTime: currentTime)
            }
        }
    }

    private var audioCanvas: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = player?.currentTime().seconds.finiteOrZero ?? 0
            VStack(spacing: AppTheme.Spacing.smMd) {
                SessionWaveform(peaks: peaks, progress: duration > 0 ? currentTime / duration : 0)
                    .frame(height: AppTheme.Workbench.waveformHeight)
                transportRow(currentTime: currentTime, includeAdvancedControls: false)
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private func videoControls(currentTime: Double) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Slider(
                value: Binding(
                    get: { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 },
                    set: { seek(to: $0) }
                ),
                in: 0...1
            )
            .disabled(player == nil || duration <= 0)
            transportRow(currentTime: currentTime, includeAdvancedControls: true)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(AppTheme.Background.surfaceColor)
    }

    private func transportRow(currentTime: Double, includeAdvancedControls: Bool) -> some View {
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

            if !includeAdvancedControls {
                Slider(
                    value: Binding(
                        get: { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 },
                        set: { seek(to: $0) }
                    ),
                    in: 0...1
                )
                .disabled(player == nil || duration <= 0)
            }

            Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Spacer(minLength: AppTheme.Spacing.sm)

            if includeAdvancedControls {
                subtitleMenu
                speedMenu
                Button {
                    toggleFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.bordered)
                .disabled(playerViewRef == nil)
                .help("Fullscreen")
            }
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                subtitleMode = .off
            } label: {
                labelWithCheck("Off", selected: subtitleMode == .off)
            }
            Button {
                subtitleMode = .original
            } label: {
                labelWithCheck("Original", selected: subtitleMode == .original)
            }
            if !translationTracks.isEmpty {
                Divider()
                ForEach(translationTracks) { track in
                    Button {
                        subtitleMode = .translation(track.languageCode)
                    } label: {
                        labelWithCheck(
                            track.displayLanguageLabel,
                            selected: {
                                if case .translation(let code) = subtitleMode {
                                    return code.caseInsensitiveCompare(track.languageCode) == .orderedSame
                                }
                                return false
                            }()
                        )
                    }
                }
            }
        } label: {
            Text("CC")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    subtitleMode == .off
                        ? AppTheme.Background.raisedColor
                        : AppTheme.Text.primaryColor,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                )
                .foregroundStyle(subtitleMode == .off ? AppTheme.Text.primaryColor : AppTheme.Background.baseColor)
        }
        .menuStyle(.borderlessButton)
        .disabled(subtitleTrack == nil && translationTracks.isEmpty)
        .help("Subtitles")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(AppTheme.Workbench.playbackRates, id: \.self) { rate in
                Button {
                    playbackRate = rate
                    if isPlaying { player?.rate = Float(rate) }
                } label: {
                    labelWithCheck(speedLabel(rate), selected: abs(playbackRate - rate) < 0.001)
                }
            }
        } label: {
            Text("Speed \(speedLabel(playbackRate))")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        }
        .menuStyle(.borderlessButton)
        .help("Playback speed")
    }

    @ViewBuilder
    private func labelWithCheck(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func speedLabel(_ rate: Double) -> String {
        if abs(rate - 1) < 0.001 { return "1x" }
        if rate == Double(Int(rate)) { return "\(Int(rate))x" }
        return String(format: "%gx", rate)
    }

    private func activeSubtitleText(at time: Double) -> String? {
        guard !activeSubtitleCues.isEmpty else { return nil }
        return activeSubtitleCues.first(where: { time >= $0.start && time < $0.end })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    @MainActor
    private func load() async {
        player?.pause()
        isPlaying = false
        peaks = []
        duration = 0
        playerViewRef = nil
        guard let URL else {
            player = nil
            return
        }
        _ = AVPlayerView.self
        let nextPlayer = AVPlayer(url: URL)
        nextPlayer.defaultRate = Float(playbackRate)
        player = nextPlayer
        duration = (try? await nextPlayer.currentItem?.asset.load(.duration).seconds)?.finiteOrZero ?? 0
        if !showsVideoCanvas {
            peaks = (try? await WaveformExtractor.peakEnvelope(from: URL)) ?? []
        }
        if subtitleTrack != nil {
            subtitleMode = .original
        } else if let first = translationTracks.first {
            subtitleMode = .translation(first.languageCode)
        } else {
            subtitleMode = .off
        }
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
            player.rate = Float(playbackRate)
        }
        isPlaying.toggle()
    }

    private func seek(to progress: Double) {
        guard let player, duration > 0 else { return }
        seekAbsolute(to: progress * duration)
    }

    private func seekAbsolute(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: AppTheme.Workbench.playerTimescale),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    private func toggleFullscreen() {
        guard let view = playerViewRef else { return }
        if view.isInFullScreenMode {
            view.exitFullScreenMode(options: nil)
            return
        }
        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        view.enterFullScreenMode(screen, withOptions: [
            .fullScreenModeApplicationPresentationOptions: NSApplication.PresentationOptions([
                .autoHideDock,
                .autoHideMenuBar,
            ]).rawValue,
        ])
    }
}

private enum SessionSubtitleDisplayMode: Equatable {
    case off
    case original
    case translation(String)
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

/// AppKit-backed preview avoids SwiftUI `VideoPlayer` metadata crashes on macOS.
private struct SessionAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var onViewReady: ((AVPlayerView) -> Void)?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        DispatchQueue.main.async { onViewReady?(view) }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        DispatchQueue.main.async { onViewReady?(nsView) }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        if nsView.isInFullScreenMode {
            nsView.exitFullScreenMode(options: nil)
        }
        nsView.player?.pause()
        nsView.player = nil
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

private struct SessionSummaryPanel: View {
    let session: WorkbenchSession
    let onOpenTemplate: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Text("Summary")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                Spacer()
                if session.summaryMarkdown != nil {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Regenerate summary")
                }
                Button("My Template", systemImage: "doc.text", action: onOpenTemplate)
                    .buttonStyle(.bordered)
            }

            if session.summaryState == .running {
                ProgressView("Generating summary…")
                    .controlSize(.small)
            } else if let markdown = session.summaryMarkdown, !markdown.isEmpty {
                ScrollView {
                    Text(markdown)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: AppTheme.Workbench.emptyStateMinHeight / 2, maxHeight: 280)
            } else if let error = session.summaryErrorMessage {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else {
                Text("Summary will generate automatically after transcription when an LLM is configured.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
    }
}

private struct SessionTemplateSheet: View {
    let session: WorkbenchSession
    let promptMessage: String?
    let onCancel: () -> Void
    let onApply: (SummaryTemplateDefinition) -> Void

    @State private var templates: [SummaryTemplateDefinition] = SummaryTemplateDefinition.locallySupported
    @State private var selectedID = SummaryTemplateDefinition.generalSummaryID
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("My Template")
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            Text("Choose a template and edit requirement before applying")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            if let promptMessage {
                Text(promptMessage)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.warningColor)
            }

            if isLoading {
                ProgressView("Loading templates…")
            } else if let loadError {
                Text(loadError)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Templates")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    ForEach(templates) { template in
                        Button {
                            selectedID = template.id
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(template.name)
                                Spacer()
                                if selectedID == template.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(AppTheme.Spacing.smMd)
                            .background(
                                selectedID == template.id
                                    ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Local Studio currently supports only the general fallback template.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .frame(width: 220, alignment: .leading)

                if let selected = templates.first(where: { $0.id == selectedID }) ?? templates.first {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                        Text("Name")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Text(selected.name)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                        Text("Summary requirement")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        ScrollView {
                            Text(selected.userEdition)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 220)
                        .padding(AppTheme.Spacing.md)
                        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let selected = templates.first(where: { $0.id == selectedID }) ?? templates.first {
                        onApply(selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(templates.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(width: 720, height: 480)
        .task { await loadTemplates() }
    }

    @MainActor
    private func loadTemplates() async {
        guard AccountService.shared.isSignedIn else {
            templates = SummaryTemplateDefinition.locallySupported
            selectedID = SummaryTemplateDefinition.generalSummaryID
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let token: String? = {
                if case .authenticated(let value) = AccountService.shared.authState {
                    return value
                }
                return nil
            }()
            let remote = try await SummaryTemplateCatalog.shared.fetchSupportedTemplates(
                isSignedIn: true,
                authToken: token
            )
            templates = remote
            selectedID = remote.first?.id ?? SummaryTemplateDefinition.generalSummaryID
        } catch {
            loadError = error.localizedDescription
            templates = SummaryTemplateDefinition.locallySupported
            selectedID = SummaryTemplateDefinition.generalSummaryID
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
