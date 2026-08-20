import AppKit
import AVFoundation
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct RecentSessionsView: View {
    @Bindable private var store = WorkbenchStore.shared
    @State private var searchText = ""
    @State private var sessionPendingDeletion: WorkbenchSession?

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
                            SessionListRow(
                                session: session,
                                onOpen: { store.openSession(session.id) },
                                onDelete: { sessionPendingDeletion = session }
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
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

private struct SessionListRow: View {
    let session: WorkbenchSession
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
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
                Spacer(minLength: AppTheme.Spacing.zero)
                SessionStatusBadge(state: session.state)
                Color.clear
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
        .background(
            isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    isHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
        .overlay(alignment: .trailing) {
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .opacity(isHovered ? AppTheme.Opacity.zero : AppTheme.Opacity.opaque)
                    .scaleEffect(isHovered ? 0.75 : 1)
                    .allowsHitTesting(false)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                        .background(
                            AppTheme.Status.errorColor.opacity(AppTheme.Opacity.soft),
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(
                                    AppTheme.Status.errorColor.opacity(AppTheme.Opacity.moderate),
                                    lineWidth: AppTheme.BorderWidth.thin
                                )
                        }
                }
                .buttonStyle(.plain)
                .help("Delete session")
                .opacity(isHovered ? AppTheme.Opacity.opaque : AppTheme.Opacity.zero)
                .scaleEffect(isHovered ? 1 : 0.75)
                .allowsHitTesting(isHovered)
            }
            .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            .padding(.trailing, AppTheme.Spacing.lgXl)
        }
        .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }

    private func sessionKind(_ session: WorkbenchSession) -> String {
        if session.source == .standaloneDub { return "Dub" }
        return session.hasDub ? "Transcript + Dub" : "Transcript"
    }
}

struct WorkbenchSessionDetailView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared
    @State private var selectedTrack = SessionPlaybackTrack.original
    @State private var selectedTab = SessionDetailTab.transcript
    /// `nil` means Original; otherwise a translation language code.
    @State private var transcriptLanguageCode: String?
    @State private var subtitleLanguageCode: String?
    @State private var isRenamingTitle = false
    @State private var showTranslateSheet = false
    @State private var showExportSheet = false
    @State private var showDubOptionsSheet = false
    @State private var showRetranscribeSheet = false
    @State private var showTemplateLoginAlert = false
    @State private var showSummaryRefinementSheet = false
    @State private var sessionPendingDeletion: WorkbenchSession?
    @State private var isOpeningClip = false
    @State private var cuePlaybackRequest: SessionCuePlaybackRequest?
    @State private var activePlaybackCueID: Int?
    @State private var probedMediaURL: URL?
    @State private var probedMediaHasVideo = false

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
            activePlaybackCueID = nil
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
        .sheet(isPresented: $showExportSheet) {
            if let session = store.selectedSession {
                SessionExportCenter(
                    session: session,
                    preferredContent: selectedTab == .subtitles ? .subtitle : .transcript,
                    onCancel: { showExportSheet = false }
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
        .sheet(isPresented: $showSummaryRefinementSheet) {
            if let session = store.selectedSession {
                SessionSummaryRefinementSheet(
                    session: session,
                    onCancel: { showSummaryRefinementSheet = false },
                    onSubmit: { prompt in
                        showSummaryRefinementSheet = false
                        if let transcriptionID = session.transcriptionID {
                            store.regenerateSummary(
                                forTranscription: transcriptionID,
                                userPrompt: prompt
                            )
                        } else if let dubID = session.dubID {
                            store.regenerateSummary(forDub: dubID, userPrompt: prompt)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showRetranscribeSheet) {
            if let session = store.selectedSession,
               let transcriptionID = session.transcriptionID,
               let job = store.transcriptions.first(where: { $0.id == transcriptionID }) {
                ProcessingOptionsSheet(
                    mediaURLs: [job.sourceURL],
                    mode: .retranscribe,
                    initialOptions: job.processingOptions,
                    initialPlacement: job.placement,
                    onPrepareCloud: { placement in
                        await store.prepareCloudAccess(for: placement)
                    },
                    onCancel: { showRetranscribeSheet = false },
                    onContinue: { submission in
                        if submission.placement.compute == .local {
                            guard models.hasRequiredTranscriptionModels(
                                languageCode: submission.options.languageCode,
                                speakerCount: submission.options.speakerCount.count
                            ) else {
                                models.presentManager()
                                return
                            }
                        }
                        showRetranscribeSheet = false
                        store.retranscribe(transcriptionID, submission: submission)
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

    @ViewBuilder
    private func sessionView(_ session: WorkbenchSession) -> some View {
        let mediaURL = selectedTrack == .dub ? session.outputURL : session.sourceURL
        let playbackCueScope = cueScope(for: session)
        let playbackCues = editableCues(for: session, scope: playbackCueScope)
        let hasVideo = probedMediaURL == mediaURL
            ? probedMediaHasVideo
            : mediaURL?.isMovie == true

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            sessionHeader(session)
            GeometryReader { proxy in
                let contentWidth = max(
                    proxy.size.width - AppTheme.Workbench.sessionSplitDividerHitWidth,
                    0
                )
                let minimumLeftWidth = contentWidth * AppTheme.Workbench.sessionSplitMinimumRatio
                let minimumRightWidth = min(
                    AppTheme.Workbench.sessionSplitMinimumRightWidth,
                    max(contentWidth - minimumLeftWidth, 0)
                )
                let maximumLeftWidth = max(
                    minimumLeftWidth,
                    min(
                        contentWidth * AppTheme.Workbench.sessionSplitMaximumRatio,
                        max(contentWidth - minimumRightWidth, 0)
                    )
                )
                let maximumRightWidth = max(
                    minimumRightWidth,
                    contentWidth - minimumLeftWidth
                )

                HSplitView {
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
                            highlightCues: playbackCues,
                            activeCueID: $activePlaybackCueID,
                            cuePlaybackRequest: $cuePlaybackRequest,
                            onSelectTrack: { selectedTrack = $0 }
                        )
                        .layoutPriority(1)
                        SessionSummaryPanel(
                            session: session,
                            onOpenTemplate: {
                                presentTemplateLoginPrompt()
                            },
                            onRequestRefinement: { showSummaryRefinementSheet = true }
                        )
                        .frame(
                            minHeight: AppTheme.Workbench.summaryPanelMinHeight,
                            maxHeight: hasVideo ? AppTheme.Workbench.emptyStateMinHeight : .infinity,
                            alignment: .top
                        )
                    }
                    .frame(
                        minWidth: minimumLeftWidth,
                        idealWidth: contentWidth * AppTheme.Workbench.sessionSplitDefaultRatio,
                        maxWidth: maximumLeftWidth,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .background(AppTheme.Background.baseColor)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        tabBar(session)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.top, AppTheme.Spacing.lg)
                        ScrollViewReader { proxy in
                            ScrollView {
                                sessionContent(session, activeCueID: activePlaybackCueID)
                                    .padding(.horizontal, AppTheme.Spacing.xl)
                                    .padding(.bottom, AppTheme.Spacing.xl)
                            }
                            .onAppear {
                                scrollToActiveCue(activePlaybackCueID, in: playbackCues, using: proxy)
                            }
                            .onChange(of: activePlaybackCueID) { _, cueID in
                                scrollToActiveCue(cueID, in: playbackCues, using: proxy)
                            }
                            .onChange(of: selectedTab) { _, _ in
                                scrollToActiveCue(activePlaybackCueID, in: playbackCues, using: proxy)
                            }
                            .onChange(of: transcriptLanguageCode) { _, _ in
                                scrollToActiveCue(activePlaybackCueID, in: playbackCues, using: proxy)
                            }
                            .onChange(of: subtitleLanguageCode) { _, _ in
                                scrollToActiveCue(activePlaybackCueID, in: playbackCues, using: proxy)
                            }
                        }
                    }
                    .frame(
                        minWidth: minimumRightWidth,
                        idealWidth: contentWidth * (1 - AppTheme.Workbench.sessionSplitDefaultRatio),
                        maxWidth: maximumRightWidth,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .background(AppTheme.Background.baseColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.xxl)
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
        .task(id: mediaURL) {
            await probeMediaTrack(for: mediaURL)
        }
    }

    private func probeMediaTrack(for mediaURL: URL?) async {
        guard let mediaURL else {
            probedMediaURL = nil
            probedMediaHasVideo = false
            return
        }

        let asset = AVURLAsset(url: mediaURL)
        do {
            let tracks = try await asset.load(.tracks)
            guard !Task.isCancelled else { return }
            probedMediaURL = mediaURL
            probedMediaHasVideo = tracks.contains { $0.mediaType == .video }
        } catch {
            guard !Task.isCancelled else { return }
            probedMediaURL = mediaURL
            probedMediaHasVideo = false
        }
    }

    private func sessionHeader(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.smMd) {
                    if isRenamingTitle {
                        InlineRenameField(
                            originalName: session.title,
                            placeholder: SessionTitlePolicy.autoGeneratePlaceholder,
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
                    Label {
                        Text(session.createdAt.formatted(date: .numeric, time: .shortened))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .layoutPriority(1)
                    if let filename = session.originalFilename {
                        Label(filename, systemImage: "doc")
                            .lineLimit(1)
                    }
                    Image(systemName: session.storage == .local ? "internaldrive" : "icloud")
                        .accessibilityLabel(TaskPlacementCopy.storageTooltip(for: session.storage))
                        .help(TaskPlacementCopy.storageTooltip(for: session.storage))
                    Image(systemName: session.compute == .local ? "laptopcomputer" : "cloud")
                        .accessibilityLabel(TaskPlacementCopy.computeTooltip(for: session.compute))
                        .help(TaskPlacementCopy.computeTooltip(for: session.compute))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            SessionStatusBadge(state: session.state)
            if let dubID = session.dubID {
                revisionPicker(dubID: dubID)
            }
            HStack(spacing: AppTheme.Spacing.smMd) {
                if session.sourceURL != nil || session.outputURL != nil {
                    Button {
                        createClip(from: session)
                    } label: {
                        if isOpeningClip {
                            ProgressView()
                                .controlSize(.small)
                            Text("Opening…")
                        } else {
                            Label("Create clip", systemImage: "timeline.selection")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isOpeningClip)
                    .help("Open the video editor and place this session on the timeline")
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
                .disabled(isOpeningClip)

                sessionOptionsMenu(session)
            }
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

    private func sessionOptionsMenu(_ session: WorkbenchSession) -> some View {
        let isProcessing = session.state == .running || session.state == .cancelling
        return Menu {
            if session.transcriptionID != nil {
                Button("Re-transcribe and rebuild subtitles") {
                    showRetranscribeSheet = true
                }
                .disabled(isProcessing || session.sourceURL == nil)
            }
            Divider()
            Button("Delete", role: .destructive) {
                sessionPendingDeletion = session
            }
            .disabled(isProcessing)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Session options")
        .accessibilityLabel("Session options")
    }

    private func tabBar(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.xlXxl) {
                ForEach(availableTabs(session)) { tab in
                    compositeTabButton(tab, session: session)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: AppTheme.Workbench.sessionTabBarMinHeight,
                alignment: .leading
            )
            .layoutPriority(1)

            HStack(spacing: AppTheme.Spacing.smMd) {
                if session.transcriptionID != nil || session.subtitleTrack != nil
                    || session.sourceURL != nil || session.outputURL != nil {
                    sessionActionButton(
                        systemImage: "square.and.arrow.down",
                        accessibilityLabel: "Export",
                        help: "Export transcript, subtitles, or audio"
                    ) {
                        showExportSheet = true
                    }
                }
                if session.transcriptionID != nil {
                    sessionActionButton(
                        systemImage: "character.book.closed",
                        accessibilityLabel: "Translate",
                        help: "Translate"
                    ) {
                        showTranslateSheet = true
                    }
                }
                if let URL = selectedTrack == .dub ? session.outputURL : session.sourceURL {
                    sessionActionButton(
                        systemImage: "folder",
                        accessibilityLabel: "Reveal in Finder",
                        help: "Reveal in Finder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.thin)
        }
    }

    private func sessionActionButton(
        systemImage: String,
        accessibilityLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
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
                    .menuIndicator(.hidden)
                }
            }
            .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)

            Rectangle()
                .fill(isActive ? AppTheme.Accent.primary : Color.clear)
                .frame(height: AppTheme.BorderWidth.thick)
        }
    }

    @ViewBuilder
    private func sessionContent(_ session: WorkbenchSession, activeCueID: Int?) -> some View {
        let scope = cueScope(for: session)
        let cues = editableCues(for: session, scope: scope)
        let allowsEditing = selectedTab == .subtitles
            || scope == .transcript
            || !hasFineGrainedSubtitleTrack(session, scope: scope)
        SessionSegmentEditor(
            sessionID: session.id,
            contentKey: "\(session.id.uuidString)-\(selectedTab.rawValue)-\(scope.contentKey)-\(allowsEditing)",
            scope: scope,
            cues: cues,
            activeCueID: activeCueID,
            speakerLabels: speakerLabels(for: session, cues: cues),
            allowsEditing: allowsEditing,
            showsSubtitleDisplayText: selectedTab == .subtitles,
            emptyText: selectedTab == .transcript
                ? "No timed transcript is available for this track."
                : "No subtitle track is available.",
            onSeek: { start, end in
                cuePlaybackRequest = SessionCuePlaybackRequest(start: start, end: end)
            }
        )
    }

    private func scrollToActiveCue(
        _ cueID: Int?,
        in cues: [SubtitleCue],
        using proxy: ScrollViewProxy
    ) {
        guard let cueID, cues.contains(where: { $0.id == cueID }) else { return }
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            proxy.scrollTo(cueID, anchor: .center)
        }
    }

    private func cueScope(for session: WorkbenchSession) -> WorkbenchStore.SessionCueScope {
        if selectedTrack == .dub { return .dub }
        let languageCode = selectedTab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
        if let languageCode { return .translation(languageCode) }
        return selectedTab == .transcript ? .transcript : .source
    }

    private func hasFineGrainedSubtitleTrack(
        _ session: WorkbenchSession,
        scope: WorkbenchStore.SessionCueScope
    ) -> Bool {
        switch scope {
        case .transcript:
            return false
        case .source:
            return session.subtitleTrack?.cues.isEmpty == false
        case .translation(let languageCode):
            return session.translationTracks.contains {
                $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
                    && !$0.track.cues.isEmpty
            }
        case .dub:
            return session.dubSubtitleTrack?.cues.isEmpty == false
        }
    }

    private func editableCues(
        for session: WorkbenchSession,
        scope: WorkbenchStore.SessionCueScope
    ) -> [SubtitleCue] {
        let rawCues = rawCues(for: session, scope: scope)
        guard selectedTab == .transcript else { return rawCues }
        switch scope {
        case .transcript:
            return rawCues
        case .source, .translation, .dub:
            return aggregatedTranscriptCues(for: session, scope: scope, rawCues: rawCues)
        }
    }

    private func rawCues(
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
        case .transcript:
            if let transcript = session.transcript {
                let display = transcript.segments.isEmpty
                    ? transcript.aggregatingSegments()
                    : transcript
                return SubtitleTrack.fromTranscript(display).cues
            }
            if let track = session.subtitleTrack, !track.cues.isEmpty {
                let timed = track.asTranscriptionResult(preservingWords: [])
                    .aggregatingSegments()
                return SubtitleTrack.fromTranscript(timed).cues
            }
            return []
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

    private func aggregatedTranscriptCues(
        for session: WorkbenchSession,
        scope: WorkbenchStore.SessionCueScope,
        rawCues: [SubtitleCue]
    ) -> [SubtitleCue] {
        switch scope {
        case .transcript:
            return rawCues
        case .source:
            if let track = session.subtitleTrack, !track.cues.isEmpty {
                let timed = track.asTranscriptionResult(preservingWords: session.transcript?.words ?? [])
                    .aggregatingSegments()
                return SubtitleTrack.fromTranscript(timed).cues
            }
            if let transcript = session.transcript {
                return SubtitleTrack.fromTranscript(transcript.aggregatingSegments()).cues
            }
        case .dub:
            if let transcript = session.dubTranscript {
                return SubtitleTrack.fromTranscript(transcript.aggregatingSegments()).cues
            }
        case .translation:
            break
        }
        guard !rawCues.isEmpty else { return [] }
        let language: String?
        switch scope {
        case .transcript, .source:
            language = session.transcript?.language ?? session.subtitleTrack?.language
        case .dub:
            language = session.dubTranscript?.language ?? session.dubSubtitleTrack?.language
        case .translation(let languageCode):
            language = languageCode
        }
        let words: [TranscriptionWord]
        switch scope {
        case .transcript, .source:
            words = session.transcript?.words ?? []
        case .dub:
            words = session.dubTranscript?.words ?? []
        case .translation:
            words = []
        }
        let timed = SubtitleTrack(
            sourceLanguage: language,
            language: language,
            cues: rawCues
        ).asTranscriptionResult(preservingWords: words).aggregatingSegments()
        return SubtitleTrack.fromTranscript(timed).cues
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

    private func createClip(from session: WorkbenchSession) {
        guard !isOpeningClip else { return }
        isOpeningClip = true
        Task {
            defer { isOpeningClip = false }
            do {
                try await WorkbenchEditorBridge.openSession(session)
            } catch {
                WorkbenchTipCenter.shared.show(
                    "Could not open the clip project: \(error.localizedDescription)",
                    kind: .error,
                    id: "session.create-clip.failed.\(session.id.uuidString)"
                )
            }
        }
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

private struct SessionCuePlaybackRequest: Equatable {
    let start: Double
    let end: Double
}

private struct SessionMediaPlayer: View {
    let URL: URL?
    let track: SessionPlaybackTrack
    let allowsTrackSelection: Bool
    var showsFilename = true
    var prefersVideoCanvas = false
    var subtitleTrack: SubtitleTrack? = nil
    var translationTracks: [WorkbenchTranslationTrack] = []
    let highlightCues: [SubtitleCue]
    @Binding var activeCueID: Int?
    @Binding var cuePlaybackRequest: SessionCuePlaybackRequest?
    let onSelectTrack: (SessionPlaybackTrack) -> Void

    @State private var playback = SessionPlaybackController()

    private var showsVideoCanvas: Bool {
        prefersVideoCanvas || URL?.isMovie == true
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
        .task(id: URL) {
            playback.configureSubtitles(
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks
            )
            playback.configureHighlightCues(highlightCues)
            await playback.load(url: URL, showsVideoCanvas: showsVideoCanvas)
        }
        .onChange(of: highlightCues) { _, cues in
            playback.configureHighlightCues(cues)
        }
        .onChange(of: translationTracks.map(\.id)) { _, _ in
            playback.configureSubtitles(
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks
            )
        }
        .onChange(of: subtitleTrack?.cues.count) { _, _ in
            playback.configureSubtitles(
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks
            )
        }
        .onChange(of: playback.playbackRate) { _, _ in
            playback.applyPlaybackRate()
        }
        .onChange(of: playback.activeCueID) { _, cueID in
            activeCueID = cueID
        }
        .onChange(of: cuePlaybackRequest) { _, request in
            guard let request else { return }
            playback.toggleCuePlayback(start: request.start, end: request.end)
            cuePlaybackRequest = nil
        }
        .onDisappear {
            playback.tearDown()
            activeCueID = nil
        }
    }

    private var videoCanvas: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = playback.player?.currentTime().seconds.finiteOrZero ?? 0
            let cueText = playback.activeSubtitleText(at: currentTime)
            let isVideoReady = playback.playerViewRef?.playerLayer.isReadyForDisplay == true
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.black
                    if let player = playback.player {
                        SessionAVPlayerRepresentable(
                            player: player,
                            onViewReady: { playback.playerViewRef = $0 }
                        )
                        .allowsHitTesting(false)
                        if !isVideoReady {
                            if let posterImage = playback.posterImage {
                                Image(nsImage: posterImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .allowsHitTesting(false)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                    .allowsHitTesting(false)
                            }
                        }
                    } else if URL != nil {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .allowsHitTesting(false)
                    } else {
                        Text("Media unavailable")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .allowsHitTesting(false)
                    }

                    if playback.fullscreenController == nil, let cueText {
                        Text(cueText)
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.vertical, AppTheme.Spacing.smMd)
                            .background(Color.black.opacity(AppTheme.Opacity.medium), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.bottom, AppTheme.Spacing.xl)
                            .allowsHitTesting(false)
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard playback.player != nil else { return }
                            playback.toggleFullscreen()
                        }
                        .onTapGesture {
                            guard playback.player != nil else { return }
                            playback.togglePlayback()
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
            let currentTime = playback.player?.currentTime().seconds.finiteOrZero ?? 0
            VStack(spacing: AppTheme.Spacing.smMd) {
                AudioWaveformView(
                    peaks: playback.peaks,
                    progress: playback.duration > 0 ? currentTime / playback.duration : 0
                )
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
                    get: {
                        playback.duration > 0
                            ? min(1, max(0, currentTime / playback.duration))
                            : 0
                    },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...1
            )
            .disabled(playback.player == nil || playback.duration <= 0)
            transportRow(currentTime: currentTime, includeAdvancedControls: true)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(AppTheme.Background.surfaceColor)
    }

    private func transportRow(currentTime: Double, includeAdvancedControls: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(playback.player == nil)

            if !includeAdvancedControls {
                Slider(
                    value: Binding(
                        get: {
                            playback.duration > 0
                                ? min(1, max(0, currentTime / playback.duration))
                                : 0
                        },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .disabled(playback.player == nil || playback.duration <= 0)
            }

            Text("\(formatTime(currentTime)) / \(formatTime(playback.duration))")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Spacer(minLength: AppTheme.Spacing.sm)

            if includeAdvancedControls {
                subtitleMenu
                speedMenu
                Button {
                    playback.toggleFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.bordered)
                .disabled(playback.playerViewRef == nil)
                .help("Fullscreen")
            }
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                playback.subtitleMode = .off
            } label: {
                labelWithCheck("Off", selected: playback.subtitleMode == .off)
            }
            Button {
                playback.subtitleMode = .original
            } label: {
                labelWithCheck("Original", selected: playback.subtitleMode == .original)
            }
            if !playback.translationTracks.isEmpty {
                Divider()
                ForEach(playback.translationTracks) { track in
                    Button {
                        playback.subtitleMode = .translation(track.languageCode)
                    } label: {
                        labelWithCheck(
                            track.displayLanguageLabel,
                            selected: {
                                if case .translation(let code) = playback.subtitleMode {
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
                    playback.subtitleMode == .off
                        ? AppTheme.Background.raisedColor
                        : AppTheme.Text.primaryColor,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                )
                .foregroundStyle(
                    playback.subtitleMode == .off
                        ? AppTheme.Text.primaryColor
                        : AppTheme.Background.baseColor
                )
        }
        .menuStyle(.borderlessButton)
        .disabled(playback.subtitleTrack == nil && playback.translationTracks.isEmpty)
        .help("Subtitles")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(AppTheme.Workbench.playbackRates, id: \.self) { rate in
                Button {
                    playback.setPlaybackRate(rate)
                } label: {
                    labelWithCheck(speedLabel(rate), selected: abs(playback.playbackRate - rate) < 0.001)
                }
            }
        } label: {
            Text("Speed \(speedLabel(playback.playbackRate))")
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
}

struct AudioWaveformView: View {
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
    let onRequestRefinement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Text("Summary")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                Spacer()
                if (session.transcriptionID != nil || session.dubID != nil),
                   session.state != .running,
                   session.state != .cancelling,
                   session.summaryState != .running {
                    Button(action: onRequestRefinement) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.aiGradient)
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refine summary with AI")
                    .help("Tell AI what to change and regenerate the summary")
                }
                Button("My Template", systemImage: "doc.text", action: onOpenTemplate)
                    .buttonStyle(.bordered)
            }

            if session.summaryState == .running {
                ProgressView("Generating summary…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let markdown = session.summaryMarkdown, !markdown.isEmpty {
                ScrollView {
                    StructuredText(markdown: TemplateSummaryLLMProcessor.sanitizeMarkdown(markdown))
                        .textual.structuredTextStyle(.default)
                        .textual.textSelection(.enabled)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: AppTheme.Workbench.summaryPanelMinHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            } else if session.summaryState == .failed,
                      let error = session.summaryErrorMessage,
                      !error.isEmpty,
                      error != LLMConfigurationError.noConfiguredModel(.subtitleProcessing)
                        .localizedDescription {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                Text("Summary will generate automatically when an LLM is configured.")
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

private struct SessionSummaryRefinementSheet: View {
    let session: WorkbenchSession
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var prompt = ""
    @FocusState private var isPromptFocused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Refine summary")
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                Text("Tell AI what to change. The selected template requirements remain active.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                if let templateName = session.summaryTemplateName,
                   !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Template: \(templateName)")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .scrollContentBackground(.hidden)
                    .padding(AppTheme.Spacing.sm)
                    .focused($isPromptFocused)

                if trimmedPrompt.isEmpty {
                    Text("For example: emphasize the findings, shorten the overview, and add a risks section.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.lg)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: AppTheme.Workbench.summaryRefinementEditorHeight)
            .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Regenerate") {
                    onSubmit(trimmedPrompt)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedPrompt.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(width: AppTheme.Workbench.summaryRefinementSheetWidth)
        .task {
            isPromptFocused = true
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

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remaining = total % 60
    return hours > 0
        ? String(format: "%02d:%02d:%02d", hours, minutes, remaining)
        : String(format: "%02d:%02d", minutes, remaining)
}

extension Double {
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
