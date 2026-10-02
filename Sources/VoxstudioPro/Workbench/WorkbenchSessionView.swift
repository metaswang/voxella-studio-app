import AppKit
import AVFoundation
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct RecentSessionsView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var account = AccountService.shared
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
                    TextField(L10n.string("Search sessions"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AppTheme.Workbench.searchWidth)
                }

                if store.isHydrating {
                    VStack(spacing: AppTheme.Spacing.md) {
                        ProgressView()
                        Text("Loading saved sessions…")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
                } else if filteredSessions.isEmpty && store.isLoadingRemoteSessions {
                    VStack(spacing: AppTheme.Spacing.md) {
                        ProgressView()
                        Text("Loading VoxStudio Cloud sessions…")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? L10n.string("No sessions yet") : L10n.string("No matching sessions"),
                        systemImage: "clock",
                        description: Text(searchText.isEmpty
                            ? L10n.string("Transcribe media or create a dub to start a session.")
                            : L10n.string("Try a different session name or transcript phrase."))
                    )
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
                } else {
                    LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                        ForEach(filteredSessions) { session in
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
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
        .alert(item: $sessionPendingDeletion) { session in
            Alert(
                title: Text(L10n.string("Delete session?")),
                message: Text(
                    L10n.format(
                        "\"%@\" and its saved workflow data will be removed.",
                        session.title
                    )
                ),
                primaryButton: .destructive(Text(L10n.string("Delete"))) {
                    store.deleteSession(session.id)
                },
                secondaryButton: .cancel()
            )
        }
        .task(id: account.isSignedIn) {
            if account.isSignedIn {
                await store.refreshRemoteSessions()
            } else {
                store.clearRemoteSessions()
            }
        }
    }
}

struct WorkbenchSessionDetailView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var account = AccountService.shared
    @State private var selectedTrack = SessionPlaybackTrack.original
    @State private var selectedTab = SessionDetailTab.transcript
    @State private var expandedTranscriptParagraphID: Int?
    /// `nil` means Original; otherwise a translation language code.
    @State private var transcriptLanguageCode: String?
    @State private var subtitleLanguageCode: String?
    @State private var isRenamingTitle = false
    @State private var showTranslateSheet = false
    @State private var showExportSheet = false
    @State private var showDubOptionsSheet = false
    @State private var showRetranscribeSheet = false
    @State private var showMissingSourceMediaAlert = false
    @State private var showTemplateLoginAlert = false
    @State private var showTemplateSheet = false
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
                if session.isRemoteOnly && store.remoteSessionLoadingID == session.id {
                    VStack(spacing: AppTheme.Spacing.md) {
                        ProgressView()
                        Text("Loading session data from VoxStudio Cloud…")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        sessionView(session)
                        if session.showsFloatingNetVideoPreview,
                           session.sourceURL?.isMovie != true,
                           let source = session.netVideoSource {
                            NetVideoFloatingPlayer(source: source)
                                .padding(AppTheme.Spacing.xl)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(session.id)
                }
            } else {
                ContentUnavailableView(
                    L10n.string("Session unavailable"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.string("Choose a session from Recent."))
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
                .appZoomEnvironment(presentationBoundary: true)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let session = store.selectedSession {
                SessionExportCenter(
                    session: session,
                    preferredContent: selectedTab == .subtitles ? .subtitle : .transcript,
                    onCancel: { showExportSheet = false }
                )
                .appZoomEnvironment(presentationBoundary: true)
            }
        }
        .sheet(isPresented: $showDubOptionsSheet) {
            if let session = store.selectedSession {
                SessionDubOptionsSheet(
                    session: session,
                    preferredLanguageCode: transcriptLanguageCode,
                    onCancel: { showDubOptionsSheet = false },
                    onManageVoices: {
                        showDubOptionsSheet = false
                        SettingsWindowController.shared.show(tab: .voiceLibrary)
                    },
                    onStart: { referenceVoiceID, languageCode in
                        guard let transcriptionID = session.transcriptionID else {
                            showDubOptionsSheet = false
                            return
                        }
                        Task { @MainActor in
                            guard await store.createDubAfterAccess(
                                for: transcriptionID,
                                track: languageCode == nil ? .source : .translation,
                                translationLanguageCode: languageCode,
                                refreshExistingTranscript: true,
                                referenceVoiceID: referenceVoiceID,
                                applyReferenceVoice: true
                            ) != nil else {
                                showDubOptionsSheet = false
                                return
                            }
                            showDubOptionsSheet = false
                        }
                    }
                )
                .appZoomEnvironment(presentationBoundary: true)
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
                .appZoomEnvironment(presentationBoundary: true)
            }
        }
        .sheet(isPresented: $showTemplateSheet) {
            if let session = store.selectedSession {
                SessionSummaryTemplateSheet(
                    currentTemplateID: session.summaryTemplateID,
                    onCancel: { showTemplateSheet = false },
                    onApply: { template in
                        showTemplateSheet = false
                        store.applySummaryTemplate(template, to: session)
                    }
                )
                .appZoomEnvironment(presentationBoundary: true)
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
                        guard !WorkbenchSession.isSourceMediaMissing(at: job.sourceURL) else {
                            showRetranscribeSheet = false
                            showMissingSourceMediaAlert = true
                            return
                        }
                        showRetranscribeSheet = false
                        store.retranscribe(transcriptionID, submission: submission)
                    }
                )
                .appZoomEnvironment(presentationBoundary: true)
            }
        }
        .alert(
            L10n.string("Media file not found"),
            isPresented: $showMissingSourceMediaAlert
        ) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "The original media file for this session is no longer available. Restore it to its original location before re-transcribing."
            ))
        }
        .alert(L10n.string("My Template"), isPresented: $showTemplateLoginAlert) {
            Button(L10n.string("Open voxstudio.me")) {
                if let url = URL(string: "https://voxstudio.me") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(L10n.string("Sign in at voxstudio.me to choose and edit summary templates."))
        }
        .alert(item: $sessionPendingDeletion) { session in
            Alert(
                title: Text(L10n.string("Delete session?")),
                message: Text(
                    L10n.format(
                        "\"%@\" and its saved workflow data will be removed.",
                        session.title
                    )
                ),
                primaryButton: .destructive(Text(L10n.string("Delete"))) {
                    store.deleteSession(session.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func sessionView(_ session: WorkbenchSession) -> some View {
        let originalMediaURL = session.originalPlaybackURL
        // Cloud High-Fidelity Repair or local listen enhance — same player switch as web Audio Source.
        let enhancedMediaURL = session.processedPlaybackURL
        let hasCloudRepair = session.enhancedPlaybackURL != nil
        let dubbedMediaURL = session.outputURL
        let originalHasInlineVideo = sessionHasInlineVideo(session, mediaURL: originalMediaURL)
        let mediaURL: URL? = switch selectedTrack {
        case .dub:
            dubbedMediaURL
        case .enhanced:
            originalHasInlineVideo ? originalMediaURL : (enhancedMediaURL ?? originalMediaURL)
        case .original:
            originalMediaURL
        }
        let playbackCueScope = cueScope(for: session)
        let playbackCues = editableCues(for: session, scope: playbackCueScope)
        let hasInlineVideo = sessionHasInlineVideo(session, mediaURL: mediaURL)
        let secondaryAudioURL = selectedTrack == .enhanced && hasInlineVideo
            ? enhancedMediaURL
            : nil

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
                    sessionMediaAndSummary(
                        session: session,
                        mediaURL: mediaURL,
                        originalMediaURL: originalMediaURL,
                        enhancedMediaURL: enhancedMediaURL,
                        hasCloudRepair: hasCloudRepair,
                        dubbedMediaURL: dubbedMediaURL,
                        secondaryAudioURL: secondaryAudioURL,
                        hasInlineVideo: hasInlineVideo,
                        playbackCues: playbackCues,
                        contentHeight: proxy.size.height
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
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
                    .background(SessionTranscriptCanvas.color)
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
            if session.sourceURL == nil && session.outputURL != nil {
                selectedTrack = .dub
            } else if selectedTrack == .original, enhancedMediaURL != nil {
                selectedTrack = .enhanced
            }
            selectedTab = availableTabs(session).first ?? .transcript
            syncLanguageSelections(session)
        }
        .onChange(of: session.id) { _, _ in
            syncLanguageSelections(session)
        }
        .onChange(of: session.translationTracks) { _, _ in
            syncLanguageSelections(session)
        }
        .onChange(of: session.selectedTranslationLanguageCode) { _, _ in
            syncLanguageSelections(session)
        }
        .onChange(of: enhancedMediaURL) { _, enhancedURL in
            if selectedTrack == .enhanced, enhancedURL == nil {
                selectedTrack = .original
            } else if selectedTrack == .original, enhancedURL != nil {
                selectedTrack = .enhanced
            }
        }
        .task(id: mediaURL) {
            await probeMediaTrack(for: mediaURL)
        }
    }

    private func sessionHasInlineVideo(_ session: WorkbenchSession, mediaURL: URL?) -> Bool {
        if session.showsFloatingNetVideoPreview, selectedTrack == .original, session.sourceURL?.isMovie != true {
            return false
        }
        if selectedTrack != .dub, session.remoteSourceHasVideo == true {
            return true
        }
        if probedMediaURL == mediaURL {
            return probedMediaHasVideo
        }
        return mediaURL?.isMovie == true
    }

    @ViewBuilder
    private func sessionMediaAndSummary(
        session: WorkbenchSession,
        mediaURL: URL?,
        originalMediaURL: URL?,
        enhancedMediaURL: URL?,
        hasCloudRepair: Bool,
        dubbedMediaURL: URL?,
        secondaryAudioURL: URL?,
        hasInlineVideo: Bool,
        playbackCues: [SubtitleCue],
        contentHeight: CGFloat
    ) -> some View {
        if hasInlineVideo {
            let summaryIdealHeight = max(
                AppTheme.Workbench.summaryPanelMinHeight,
                contentHeight * AppTheme.Workbench.sessionSummaryDefaultRatio
            )
            let videoIdealHeight = max(
                0,
                contentHeight - summaryIdealHeight
            )
            let videoMinHeight = videoIdealHeight > 0
                ? min(AppTheme.Workbench.sessionVideoMinHeight, videoIdealHeight)
                : AppTheme.Workbench.sessionVideoMinHeight
            VSplitView {
                sessionPlaybackPlayer(
                    session: session,
                    mediaURL: mediaURL,
                    originalMediaURL: originalMediaURL,
                    enhancedMediaURL: enhancedMediaURL,
                    hasCloudRepair: hasCloudRepair,
                    dubbedMediaURL: dubbedMediaURL,
                    secondaryAudioURL: secondaryAudioURL,
                    hasInlineVideo: true,
                    playbackCues: playbackCues
                )
                .frame(
                    minHeight: videoMinHeight,
                    idealHeight: videoIdealHeight,
                    maxHeight: .infinity,
                    alignment: .top
                )
                sessionSummary(session)
                    .frame(
                        minHeight: summaryIdealHeight,
                        idealHeight: summaryIdealHeight,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .layoutPriority(1)
            }
        } else {
            sessionSummary(session)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    sessionPlaybackPlayer(
                        session: session,
                        mediaURL: mediaURL,
                        originalMediaURL: originalMediaURL,
                        enhancedMediaURL: enhancedMediaURL,
                        hasCloudRepair: hasCloudRepair,
                        dubbedMediaURL: dubbedMediaURL,
                        secondaryAudioURL: secondaryAudioURL,
                        hasInlineVideo: false,
                        playbackCues: playbackCues
                    )
                }
        }
    }

    private func sessionPlaybackPlayer(
        session: WorkbenchSession,
        mediaURL: URL?,
        originalMediaURL: URL?,
        enhancedMediaURL: URL?,
        hasCloudRepair: Bool,
        dubbedMediaURL: URL?,
        secondaryAudioURL: URL?,
        hasInlineVideo: Bool,
        playbackCues: [SubtitleCue]
    ) -> some View {
        SessionMediaPlayer(
            URL: mediaURL,
            track: selectedTrack,
            availableTracks: SessionPlaybackTrack.available(
                originalURL: originalMediaURL,
                enhancedURL: enhancedMediaURL,
                dubbedURL: dubbedMediaURL
            ),
            allowsTrackSelection: SessionPlaybackTrack.available(
                originalURL: originalMediaURL,
                enhancedURL: enhancedMediaURL,
                dubbedURL: dubbedMediaURL
            ).count > 1,
            hasCloudRepair: hasCloudRepair,
            secondaryAudioURL: secondaryAudioURL,
            showsFilename: false,
            prefersVideoCanvas: hasInlineVideo,
            subtitleTrack: selectedTrack == .dub
                ? session.dubSubtitleTrack
                : session.subtitleTrack,
            translationTracks: session.translationTracks,
            highlightCues: playbackCues,
            activeCueID: $activePlaybackCueID,
            cuePlaybackRequest: $cuePlaybackRequest,
            onSelectTrack: { selectedTrack = $0 }
        )
    }

    private func sessionSummary(_ session: WorkbenchSession) -> some View {
        SessionSummaryPanel(
            session: session,
            onOpenTemplate: {
                presentTemplatePicker()
            },
            onRequestRefinement: { showSummaryRefinementSheet = true }
        )
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
                        .help(L10n.string("Rename session"))
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
                    if let netVideoSource = session.netVideoSource {
                        Button {
                            NSWorkspace.shared.open(netVideoSource.sourceURL)
                        } label: {
                            Label {
                                Text(netVideoSource.sourceURL.absoluteString)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "link")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .help(L10n.string("Open source page"))
                    } else if let filename = session.originalFilename {
                        sourceFileLabel(filename, isMissing: session.isSourceMediaMissing)
                            .lineLimit(1)
                    }
                    SessionPlacementIndicators(
                        storage: session.storage,
                        compute: session.compute
                    )
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                cloudSyncStatus(session)
            }
            Spacer()
            HStack(spacing: AppTheme.Spacing.xs) {
                SessionStatusBadge(
                    status: session.status,
                    processing: sessionProcessingSnapshot(for: session)
                )
                SessionStatusInfoButton(status: session.status)
            }
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
                            Text(L10n.string("Opening…"))
                        } else {
                            Label(L10n.string("New clip"), systemImage: "timeline.selection")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isOpeningClip)
                    .help(L10n.string("Create clip"))
                    .accessibilityLabel(L10n.string("Create clip"))
                }
                Button {
                    if session.transcriptionID != nil {
                        showDubOptionsSheet = true
                    } else {
                        openWorkflow(session)
                    }
                } label: {
                    Label(
                        L10n.string(session.hasDub ? "Re-dub" : "New dub"),
                        systemImage: "waveform.and.mic"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOpeningClip)
                .help(L10n.string(session.hasDub ? "Dub again" : "Create dub"))
                .accessibilityLabel(L10n.string(session.hasDub ? "Re-dub" : "Create dub"))

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

    private func sessionProcessingSnapshot(for session: WorkbenchSession) -> SessionProcessingSnapshot? {
        if let dubID = session.dubID,
           let dub = store.dubs.first(where: { $0.id == dubID }),
           dub.isActivelyProcessing {
            return SessionProcessingSnapshot(job: dub)
        }
        if let transcriptionID = session.transcriptionID,
           let transcription = store.transcriptions.first(where: { $0.id == transcriptionID }),
           transcription.isActivelyProcessing {
            return SessionProcessingSnapshot(job: transcription)
        }
        return nil
    }

    @ViewBuilder
    private func cloudSyncStatus(_ session: WorkbenchSession) -> some View {
        if session.storage == .cloud {
            switch session.cloudSyncState {
            case .pending, .failed:
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    if session.cloudSyncError == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(L10n.display(
                            session.cloudSyncError
                                ?? "Saving changes to VoxStudio Cloud…"
                        ))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(
                            session.cloudSyncError == nil
                                ? AppTheme.Text.tertiaryColor
                                : AppTheme.Status.warningColor
                        )
                        if session.cloudSyncError != nil {
                            Button(L10n.string("Retry cloud sync")) {
                                store.retryCloudSessionSync(session.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            case .none, .completed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func revisionPicker(dubID: UUID) -> some View {
        if let dub = store.dubs.first(where: { $0.id == dubID }),
           let revisions = dub.revisions,
           revisions.count > 1 {
            Picker(L10n.string("Revision"), selection: revisionBinding(dubID)) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { offset, revision in
                    Text(L10n.format(
                        "Version %@ · %@",
                        offset + 1,
                        revision.createdAt.formatted(date: .omitted, time: .shortened)
                    ))
                        .tag(revision.id as UUID?)
                }
            }
            .labelsHidden()
            .frame(width: AppTheme.Workbench.revisionPickerWidth)
        }
    }

    private func sessionOptionsMenu(_ session: WorkbenchSession) -> some View {
        let isProcessing = session.status.showsProcessing || session.status.showsQueued
        return Menu {
            if session.transcriptionID != nil {
                Button(L10n.string(session.subtitleTrack == nil ? "Segment subtitles" : "Re-segment subtitles")) {
                    if let transcriptionID = session.transcriptionID {
                        store.prepareSubtitles(transcriptionID)
                    }
                }
                .disabled(isProcessing || (session.transcript == nil && session.sourceURL == nil))
                Button(L10n.string("Re-transcribe")) {
                    if session.isSourceMediaMissing {
                        showMissingSourceMediaAlert = true
                    } else {
                        showRetranscribeSheet = true
                    }
                }
                .disabled(isProcessing || session.sourceURL == nil)
            }
            if session.isRemoteOnly, session.status.displayTaskState == .unknown {
                Button(L10n.string("Refresh status")) {
                    Task { await store.refreshRemoteSessions() }
                }
            }
            Divider()
            Button(L10n.string("Delete"), role: .destructive) {
                sessionPendingDeletion = session
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.string("Session options"))
        .accessibilityLabel(L10n.string("Session options"))
    }

    private func sourceFileLabel(_ filename: String, isMissing: Bool) -> some View {
        let accessibilityLabel = isMissing
            ? filename + ". " + L10n.string(
                "Source file unavailable. It may have been moved or deleted. Restore it to its original location to play or re-transcribe this session."
            )
            : filename

        return HStack(spacing: AppTheme.Spacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "doc")
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .background(AppTheme.Background.surfaceColor, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            Text(filename)
        }
        .help(isMissing ? L10n.string(
            "Source file unavailable. It may have been moved or deleted. Restore it to its original location to play or re-transcribe this session."
        ) : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
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
        .accessibilityLabel(L10n.string(key: accessibilityLabel))
        .help(L10n.string(key: help))
    }

    @ViewBuilder
    private func compositeTabButton(_ tab: SessionDetailTab, session: WorkbenchSession) -> some View {
        let isActive = selectedTab == tab
        let languageCode = tab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
        let hasTranslations = !session.translationTracks.isEmpty

        VStack(spacing: AppTheme.Spacing.sm) {
            ZStack(alignment: .trailing) {
                Button {
                    selectedTab = tab
                } label: {
                    Text(L10n.string(key: tab.title))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if hasTranslations {
                    Menu {
                        Picker(L10n.string("Language"), selection: languageChoiceBinding(for: tab, session: session)) {
                            Text(L10n.string("Original")).tag(SessionLanguageChoice.original)
                            Divider()
                            ForEach(session.translationTracks) { track in
                                Text(languageMenuTitle(track))
                                    .tag(SessionLanguageChoice.translation(track.languageCode))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
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
                    .id(languageMenuIdentity(for: tab, session: session))
                }
            }
            .frame(minWidth: 108, minHeight: 24)
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
        let allowsEditing = !session.isRemoteOnly && (selectedTab == .subtitles
            || scope == .transcript
            || !hasFineGrainedSubtitleTrack(session, scope: scope))
        SessionSegmentEditor(
            sessionID: session.id,
            contentKey: "\(session.id.uuidString)-\(selectedTab.rawValue)-\(scope.contentKey)-\(allowsEditing)",
            scope: scope,
            cues: cues,
            activeCueID: activeCueID,
            speakerLabels: speakerLabels(for: session, cues: cues),
            speakerDisplayNames: session.isRemoteOnly ? store.remoteSpeakerNames[session.id] ?? [:] : [:],
            allowsEditing: allowsEditing,
            showsSubtitleDisplayText: selectedTab == .subtitles,
            aggregatesSpeakers: selectedTab == .transcript,
            expandedParagraphID: $expandedTranscriptParagraphID,
            emptyText: selectedTab == .transcript
                ? L10n.string("No timed transcript is available for this track.")
                : L10n.string("No subtitle track is available."),
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
            let target = SessionTranscriptDisplayRow.scrollID(
                cueID: cueID, in: cues, aggregate: selectedTab == .transcript,
                expandedID: expandedTranscriptParagraphID
            )
            proxy.scrollTo(target, anchor: .center)
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

    private func languageChoiceBinding(
        for tab: SessionDetailTab,
        session: WorkbenchSession
    ) -> Binding<SessionLanguageChoice> {
        Binding(
            get: {
                let code = tab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
                guard let code,
                      let canonical = session.translationTracks.first(where: {
                          $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
                      })?.languageCode
                else { return .original }
                return .translation(canonical)
            },
            set: { choice in
                selectedTab = tab
                switch choice {
                case .original:
                    setLanguage(nil, for: tab, session: session)
                case .translation(let code):
                    setLanguage(code, for: tab, session: session)
                }
            }
        )
    }

    private func languageMenuTitle(_ track: WorkbenchTranslationTrack) -> String {
        "\(track.displayLanguageLabel) · \(L10n.format("%@ cues", track.track.cues.count))"
    }

    private func languageMenuIdentity(for tab: SessionDetailTab, session: WorkbenchSession) -> String {
        let code = tab == .transcript ? transcriptLanguageCode : subtitleLanguageCode
        let tracks = session.translationTracks.map(\.languageCode).joined(separator: ",")
        return "\(tab.rawValue)|\(code ?? "")|\(tracks)"
    }

    private func setLanguage(_ code: String?, for tab: SessionDetailTab, session: WorkbenchSession) {
        let canonical = code.flatMap { raw in
            session.translationTracks.first {
                $0.languageCode.caseInsensitiveCompare(raw) == .orderedSame
            }?.languageCode
        }
        switch tab {
        case .transcript:
            transcriptLanguageCode = canonical
        case .subtitles:
            subtitleLanguageCode = canonical
        }
        store.rememberDisplayLanguage(
            canonical,
            for: tab == .transcript ? .transcript : .subtitles,
            session: session
        )
    }

    private func syncLanguageSelections(_ session: WorkbenchSession) {
        transcriptLanguageCode = store.displayLanguage(for: .transcript, session: session)
        subtitleLanguageCode = store.displayLanguage(for: .subtitles, session: session)
    }

    private func presentTemplatePicker() {
        if account.isSignedIn {
            showTemplateSheet = true
        } else {
            showTemplateLoginAlert = true
        }
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
            Task { @MainActor in
                _ = await store.createDubAfterAccess(for: transcriptionID)
            }
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
    case enhanced
    case dub

    var id: String { rawValue }

    func title(hasCloudRepair: Bool) -> String {
        switch self {
        case .original: "Original"
        case .enhanced: hasCloudRepair ? "High-Fidelity Repair" : "Enhanced"
        case .dub: "Dub"
        }
    }

    static func available(
        originalURL: URL?,
        enhancedURL: URL?,
        dubbedURL: URL?
    ) -> [SessionPlaybackTrack] {
        var tracks: [SessionPlaybackTrack] = []
        if originalURL != nil { tracks.append(.original) }
        if enhancedURL != nil { tracks.append(.enhanced) }
        if dubbedURL != nil { tracks.append(.dub) }
        return tracks
    }
}

private enum SessionLanguageChoice: Hashable {
    case original
    case translation(String)
}

private enum PlaybackSubtitleChoice: Hashable {
    case none
    case original
    case translation(String)
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
    let onStart: (UUID?, String?) -> Void
    @State private var referenceVoiceID: UUID?
    @State private var selectedLanguageCode: String

    init(
        session: WorkbenchSession,
        preferredLanguageCode: String?,
        onCancel: @escaping () -> Void,
        onManageVoices: @escaping () -> Void,
        onStart: @escaping (UUID?, String?) -> Void
    ) {
        self.session = session
        self.onCancel = onCancel
        self.onManageVoices = onManageVoices
        self.onStart = onStart
        let selected = session.translationTracks.first {
            $0.languageCode.caseInsensitiveCompare(preferredLanguageCode ?? "") == .orderedSame
        }?.languageCode ?? ""
        _selectedLanguageCode = State(initialValue: selected)
    }

    private var languageCode: String {
        session.translationTracks.first {
            $0.languageCode.caseInsensitiveCompare(selectedLanguageCode) == .orderedSame
        }?.languageCode
            ?? session.transcript?.language
            ?? session.subtitleTrack?.language
            ?? "auto"
    }

    private var speakers: [String] {
        let selectedTranslation = session.translationTracks.first {
            $0.languageCode.caseInsensitiveCompare(selectedLanguageCode) == .orderedSame
        }
        let values = selectedTranslation.map { $0.track.cues.compactMap(\.speaker) }
            ?? (session.transcript?.segments.compactMap(\.speaker) ?? [])
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
                if !session.translationTracks.isEmpty {
                    Picker("Target language", selection: $selectedLanguageCode) {
                        Text("Original").tag("")
                        ForEach(session.translationTracks) { track in
                            Text(track.displayLanguageLabel).tag(track.languageCode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                    onStart(referenceVoiceID, selectedLanguageCode.isEmpty ? nil : selectedLanguageCode)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.zoomed(620))
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
                        Text(L10n.string(key: option.label)).tag(option.languageCode ?? "")
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, AppTheme.Spacing.smMd)
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
        .frame(width: AppTheme.zoomed(520))
    }
}

private struct SessionCuePlaybackRequest: Equatable {
    let start: Double
    let end: Double
}

private struct SessionMediaPlayer: View {
    let URL: URL?
    let track: SessionPlaybackTrack
    let availableTracks: [SessionPlaybackTrack]
    let allowsTrackSelection: Bool
    var hasCloudRepair = false
    let secondaryAudioURL: URL?
    var showsFilename = true
    var prefersVideoCanvas = false
    var subtitleTrack: SubtitleTrack? = nil
    var translationTracks: [WorkbenchTranslationTrack] = []
    let highlightCues: [SubtitleCue]
    @Binding var activeCueID: Int?
    @Binding var cuePlaybackRequest: SessionCuePlaybackRequest?
    let onSelectTrack: (SessionPlaybackTrack) -> Void

    @State private var playback = SessionPlaybackController()
    @State private var hasLoadedPlayback = false

    private var showsVideoCanvas: Bool {
        prefersVideoCanvas
    }

    private var audioChromeHeight: CGFloat {
        var height = audioCanvasHeight
        if allowsTrackSelection {
            height += AppTheme.Spacing.md
                + AppTheme.Spacing.sm
                + AppTheme.Workbench.sessionTabBarMinHeight
        }
        return height
    }

    private var audioCanvasHeight: CGFloat {
        AppTheme.Workbench.sessionAudioCanvasHeight(showsSubtitles: showsAudioSubtitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            if allowsTrackSelection {
                HStack {
                    Picker("Track", selection: Binding(get: { track }, set: { value in onSelectTrack(value) })) {
                        ForEach(availableTracks) { item in
                            Text(L10n.string(key: item.title(hasCloudRepair: hasCloudRepair))).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    if showsFilename {
                        Text(URL?.lastPathComponent ?? L10n.string("Media unavailable"))
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
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous))
        .frame(
            maxHeight: showsVideoCanvas
                ? .infinity
                : audioChromeHeight
        )
        .task(id: "\(URL?.absoluteString ?? "")|\(secondaryAudioURL?.absoluteString ?? "")") {
            playback.configureSubtitles(
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks
            )
            playback.configureHighlightCues(highlightCues)
            let wasPlaying = !hasLoadedPlayback && URL != nil ? true : playback.isPlaying
            // Preserve playhead when master → listen swap completes mid-session.
            await playback.load(
                url: URL,
                showsVideoCanvas: showsVideoCanvas,
                alternateAudioURL: secondaryAudioURL,
                resumeTime: playback.currentTime > 0 ? playback.currentTime : nil,
                resumePlaying: wasPlaying
            )
            if !Task.isCancelled, playback.player != nil {
                hasLoadedPlayback = true
            }
        }
        .onChange(of: highlightCues) { _, cues in
            playback.configureHighlightCues(cues)
        }
        .onChange(of: translationTracks) { _, _ in
            playback.configureSubtitles(
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks
            )
        }
        .onChange(of: subtitleTrack) { _, _ in
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
            let currentTime = playback.currentTime
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                videoControls(currentTime: currentTime)
            }
        }
    }

    private var audioCanvas: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = playback.currentTime
            let cueText = playback.activeSubtitleText(at: currentTime)
            VStack(spacing: AppTheme.Spacing.smMd) {
                AudioWaveformView(
                    peaks: playback.peaks,
                    progress: playback.duration > 0 ? currentTime / playback.duration : 0
                )
                .frame(height: AppTheme.Workbench.waveformHeight)
                .padding(.horizontal, AppTheme.Spacing.sm)

                transportRow(currentTime: currentTime, includeAdvancedControls: false)

                if showsAudioSubtitle {
                    audioSubtitle(cueText)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
        .frame(height: audioCanvasHeight)
        .animation(.easeInOut(duration: 0.18), value: showsAudioSubtitle)
    }

    private var hasAudioSubtitles: Bool {
        playback.subtitleTrack?.cues.isEmpty == false
            || playback.translationTracks.contains(where: { !$0.track.cues.isEmpty })
    }

    private var showsAudioSubtitle: Bool {
        hasAudioSubtitles && playback.subtitleMode != .off
    }

    private func audioSubtitle(_ cueText: String?) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.primary)

            Text(cueText ?? " ")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.Workbench.audioSubtitleHeight)
        .background(
            AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .stroke(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle), lineWidth: 1)
        }
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.16), value: cueText)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Current subtitle"))
        .accessibilityValue(cueText ?? "")
    }

    private func videoControls(currentTime: Double) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            SessionPlaybackSeekBar(
                progress: playbackProgress(currentTime),
                isEnabled: playback.player != nil && playback.duration > 0,
                isPlaying: playback.isPlaying,
                onSeek: { progress, resumesPlayback in
                    playback.seek(to: progress, resumesPlayback: resumesPlayback)
                }
            )
            transportRow(currentTime: currentTime, includeAdvancedControls: true)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
            .background(AppTheme.Background.surfaceColor)
    }

    private func playbackProgress(_ currentTime: Double) -> Double {
        guard playback.duration > 0 else { return 0 }
        return min(1, max(0, currentTime / playback.duration))
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
                SessionPlaybackSeekBar(
                    progress: playbackProgress(currentTime),
                    isEnabled: playback.player != nil && playback.duration > 0,
                    isPlaying: playback.isPlaying,
                    onSeek: { progress, resumesPlayback in
                        playback.seek(to: progress, resumesPlayback: resumesPlayback)
                    }
                )
                .frame(maxWidth: .infinity)
            }

            Text("\(formatTime(currentTime)) / \(formatTime(playback.duration))")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Spacer(minLength: AppTheme.Spacing.sm)

            if playback.subtitleTrack != nil || !playback.translationTracks.isEmpty {
                subtitleMenu
            }

            if includeAdvancedControls {
                speedMenu
                Button {
                    playback.toggleFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.bordered)
                .disabled(playback.playerViewRef == nil)
                .help(L10n.string("Fullscreen"))
            }
        }
    }

    private var subtitleMenu: some View {
        HStack(spacing: 0) {
            Button {
                playback.toggleSubtitles()
            } label: {
                Text("CC")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .padding(.leading, AppTheme.Spacing.smMd)
                    .padding(.trailing, AppTheme.Spacing.xs)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(playback.subtitleMode == .off ? "Show subtitles" : "Hide subtitles"))

            if !playback.translationTracks.isEmpty {
                Menu {
                    Picker(L10n.string("Subtitles"), selection: playbackSubtitleChoice) {
                        if playback.subtitleTrack != nil {
                            Text(L10n.string("Original")).tag(PlaybackSubtitleChoice.original)
                        }
                        if playback.subtitleTrack != nil { Divider() }
                        ForEach(playback.translationTracks) { track in
                            Text(track.displayLanguageLabel)
                                .tag(PlaybackSubtitleChoice.translation(track.languageCode))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(playback.subtitleMode == .off ? AppTheme.Text.primaryColor : Color.white)
                        .frame(width: AppTheme.zoomed(20), height: AppTheme.zoomed(26))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(playback.subtitleMode == .off ? AppTheme.Text.primaryColor : Color.white)
                .fixedSize(horizontal: true, vertical: true)
                .id(playbackSubtitleMenuIdentity)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .foregroundStyle(
            playback.subtitleMode == .off
                ? AppTheme.Text.primaryColor
                : AppTheme.Background.baseColor
        )
        .background(
            playback.subtitleMode == .off
                ? AppTheme.Background.raisedColor
                : AppTheme.Text.primaryColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        )
        .disabled(playback.subtitleTrack == nil && playback.translationTracks.isEmpty)
        .help(L10n.string("Subtitles"))
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
            Text(L10n.format("Speed %@", speedLabel(playback.playbackRate)))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        }
        .menuStyle(.borderlessButton)
        .help(L10n.string("Playback speed"))
    }

    private var playbackSubtitleChoice: Binding<PlaybackSubtitleChoice> {
        Binding(
            get: {
                switch playback.subtitleMode {
                case .translation(let code):
                    let canonical = playback.translationTracks.first {
                        $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
                    }?.languageCode ?? code
                    return .translation(canonical)
                case .original:
                    return .original
                case .off:
                    return .none
                }
            },
            set: { choice in
                switch choice {
                case .none:
                    break
                case .original:
                    playback.selectSubtitleMode(.original)
                case .translation(let code):
                    playback.selectSubtitleMode(.translation(code))
                }
            }
        )
    }

    private var playbackSubtitleMenuIdentity: String {
        switch playback.subtitleMode {
        case .off:
            "off"
        case .original:
            "original"
        case .translation(let code):
            "translation:\(code)"
        }
    }

    @ViewBuilder
    private func labelWithCheck(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(L10n.display(title))
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
        .accessibilityLabel(L10n.string("Audio waveform"))
    }
}

private struct SessionSummaryPanel: View {
    let session: WorkbenchSession
    let onOpenTemplate: () -> Void
    let onRequestRefinement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Text(L10n.string("Summary"))
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
                    .accessibilityLabel(L10n.string("Refine summary with AI"))
                    .help(L10n.string("Tell AI what to change and regenerate the summary"))
                }
                Button(L10n.string("My Template"), systemImage: "doc.text", action: onOpenTemplate)
                    .buttonStyle(.bordered)
                    .disabled(session.summaryState == .running)
                    .help(session.summaryState == .running
                        ? L10n.string("Wait for the current summary to finish")
                        : session.summaryTemplateName.map { L10n.format("Template: %@", $0) }
                            ?? L10n.string("Choose a summary template"))
            }

            if let templateName = session.summaryTemplateName,
               !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(templateName, systemImage: "doc.text")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            if session.summaryState == .running {
                ProgressView(summaryGenerationLabel(for: session))
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
                Text(L10n.display(error))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                Text(L10n.string("Summary will generate automatically when an LLM is configured."))
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

    private func summaryGenerationLabel(for session: WorkbenchSession) -> String {
        guard let templateName = session.summaryTemplateName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !templateName.isEmpty else {
            return L10n.string("Generating summary…")
        }
        return L10n.format("Generating summary with %@…", templateName)
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
                Text(L10n.string("Refine summary"))
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Tell AI what to change. The selected template requirements remain active."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                if let templateName = session.summaryTemplateName,
                   !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.format("Template: %@", templateName))
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
                    Text(L10n.string("For example: emphasize the findings, shorten the overview, and add a risks section."))
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
                Button(L10n.string("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Regenerate")) {
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
