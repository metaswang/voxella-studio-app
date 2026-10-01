import SwiftUI

struct TranscribeWorkbenchView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared
    @Bindable private var connections = ProviderConnectivityStore.shared
    @State private var openingInEditorID: UUID?
    @State private var speakerEditRequest: SpeakerEditRequest?
    @State private var showProcessingOptions = false
    @State private var entryMode: TranscriptionEntryMode = .importFiles
    @State private var handledRecordingRequestID: UUID?
    @State private var netVideoURL = ""
    @State private var netVideoPhase: NetVideoImportPhase = .idle
    @State private var pendingNetVideoTitle: String?
    @State private var netVideoKind: NetVideoExtractKind = .audio
    @State private var showVideoQualityAdvanced = true
    @State private var videoQualities: [Int] = []
    @State private var selectedVideoResolution: Int?
    @State private var defaultVideoResolution: Int?
    @State private var videoQualityLoading = false
    @State private var videoQualityError: String?
    @State private var videoQualityTask: Task<Void, Never>?
    @State private var netVideoTask: Task<Void, Never>?
    @State private var netVideoImportID: UUID?
    @State private var netVideoActionHovered = false
    @State private var pendingBasicStart: PendingBasicTranscriptionStart?
    @Bindable private var recording = RecordingSessionController.shared

    var body: some View {
        Group {
            if let index = store.selectedTranscriptionIndex {
                let job = store.transcriptions[index]
                if store.shouldPresentTranscriptionProcessing(for: job.id) {
                    TranscriptionProcessingView(jobID: job.id)
                } else {
                    detail(index: index)
                }
            } else {
                emptyState
            }
        }
        .background(AppTheme.Background.baseColor)
        .onAppear {
            presentOptionsIfNeeded()
            applyPreferredEntryMode()
        }
        .onDisappear {
            netVideoTask?.cancel()
            netVideoTask = nil
            netVideoImportID = nil
        }
        .onChange(of: store.preferNetVideoEntry) { _, prefersNetVideo in
            if prefersNetVideo {
                applyPreferredEntryMode()
            }
        }
        .onChange(of: store.preferRecordEntry) { _, prefersRecord in
            if prefersRecord {
                applyPreferredEntryMode()
            }
        }
        .onChange(of: store.pendingLocalRecording) { _, _ in
            startPendingLocalRecordingIfNeeded()
        }
        .onChange(of: store.pendingMediaImportURLs) { _, urls in
            showProcessingOptions = !urls.isEmpty
        }
        .onChange(of: store.transcriptionAdmissionError) { _, message in
            // Keep empty state visible; error banner is rendered there.
            _ = message
        }
        .sheet(isPresented: $showProcessingOptions, onDismiss: {
            if !store.pendingMediaImportURLs.isEmpty {
                store.discardPendingMediaImport()
            }
            pendingNetVideoTitle = nil
        }) {
            ProcessingOptionsSheet(
                mediaURLs: store.pendingMediaImportURLs,
                initialOptions: netVideoInitialOptions,
                allowsClipSelection: store.pendingMediaImportOrigin != .netVideo,
                allowsCloudStorage: store.pendingMediaImportOrigin != .recording,
                onPrepareCloud: { placement in
                    await store.prepareCloudAccess(for: placement)
                },
                onCancel: {
                    store.discardPendingMediaImport()
                    pendingNetVideoTitle = nil
                    showProcessingOptions = false
                },
                onContinue: { submission in
                    let urls = store.pendingMediaImportURLs
                    guard !urls.isEmpty else {
                        showProcessingOptions = false
                        return
                    }
                    let netVideoSource = store.pendingNetVideoSource
                    let isRecordedCapture = store.pendingMediaImportOrigin == .recording
                    var submission = submission
                    if isRecordedCapture {
                        submission.placement.storage = .local
                    }
                    store.clearPendingMediaImport()
                    pendingNetVideoTitle = nil
                    showProcessingOptions = false
                    Task { @MainActor in
                        _ = await store.beginTranscriptionsAfterAccess(
                            sourceURLs: urls,
                            submission: submission,
                            netVideoSource: netVideoSource,
                            isRecordedCapture: isRecordedCapture
                        )
                    }
                }
            )
            .appZoomEnvironment(presentationBoundary: true)
        }
        .sheet(item: $speakerEditRequest) { request in
            SpeakerNameEditor(request: request) { name in
                commitSpeakerEdit(request, name: name)
            }
            .appZoomEnvironment(presentationBoundary: true)
        }
        .sheet(item: $pendingBasicStart) { request in
            TranscriptionAIUpgradePrompt {
                store.runTranscription(request.jobID)
            }
            .appZoomEnvironment(presentationBoundary: true)
        }
    }

    private func presentOptionsIfNeeded() {
        showProcessingOptions = !store.pendingMediaImportURLs.isEmpty
    }

    private func applyPreferredEntryMode() {
        if store.consumeRecordEntryPreference() {
            entryMode = .record
        } else if store.consumeNetVideoEntryPreference() {
            entryMode = .netVideo
        }
        startPendingLocalRecordingIfNeeded()
    }

    private func startPendingLocalRecordingIfNeeded() {
        guard let request = store.pendingLocalRecording else { return }
        guard handledRecordingRequestID != request.id else { return }
        handledRecordingRequestID = request.id
        _ = store.consumePendingLocalRecording()
        entryMode = .record
        beginLocalRecording(request)
    }

    private func beginLocalRecording(_ request: LocalRecordingRequest) {
        if recording.phase.isCapturing {
            recording.showRecordingSetup()
            return
        }
        guard recording.phase == .idle, !recording.isRequestingStart else { return }
        guard request.startImmediately else {
            recording.configuration = request.configuration(from: recording.configuration)
            return
        }
        recording.start(request)
    }

    private func detail(index: Int) -> some View {
        let job = store.transcriptions[index]
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.sessionTitle)
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    Text(job.sourcePath)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    store.selectedTranscriptionID = nil
                } label: {
                    Label(L10n.string("New transcription"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Start a new transcription task"))
                Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL]) }
                    .buttonStyle(.borderless)
                Button {
                    sendToEditor(job)
                } label: {
                    if openingInEditorID == job.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("Opening editor…"))
                        }
                    } else {
                        Label(L10n.string("Open with captions"), systemImage: "captions.bubble")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(job.result == nil || job.state.isActive || openingInEditorID != nil)
                if job.state.isActive {
                    Button(role: .cancel) {
                        store.cancelTranscription(job.id)
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(job.state == .cancelling)
                } else {
                    Button {
                        start(job)
                    } label: {
                        Label(primaryActionLabel(job), systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(AppTheme.Spacing.lgXl)

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.zoomed(18)) {
                        configuration(job)
                        processingState(job)
                        diagnostics(job)
                        transcriptEditor(job)
                    }
                    .padding(AppTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: AppTheme.zoomed(520), maxWidth: .infinity)

                Divider()
                timeline(job)
                    .frame(
                        minWidth: AppTheme.zoomed(360),
                        idealWidth: AppTheme.zoomed(430),
                        maxWidth: AppTheme.zoomed(480)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func diagnostics(_ job: WorkbenchTranscriptionJob) -> some View {
        if let diagnostics = job.diarizationDiagnostics {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "waveform.badge.checkmark")
                    .foregroundStyle(AppTheme.Status.successColor)
                VStack(alignment: .leading, spacing: AppTheme.zoomed(3)) {
                    Text("Speaker identification")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    HStack(spacing: AppTheme.Spacing.smMd) {
                        Text(L10n.format("%@ detected", diagnostics.detectedSpeakerCount))
                        if let rtf = diagnostics.realTimeFactor {
                            Text(L10n.format("RTF %@", rtf.formatted(.number.precision(.fractionLength(2)))))
                        }
                        if diagnostics.processedChunks > 0 {
                            Text(L10n.format("%@ chunks", diagnostics.processedChunks))
                        }
                        if let coverage = diagnostics.speechCoverage {
                            Text(L10n.format("%@%% speech", Int((coverage * 100).rounded())))
                        }
                        if let processed = diagnostics.processedAudioDuration {
                            Text(L10n.format("%@s processed", processed.formatted(.number.precision(.fractionLength(0)))))
                        }
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    ForEach(diagnostics.warnings, id: \.self) { warning in
                        Text(L10n.display(warning))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                }
                Spacer()
                Button(L10n.string("Reveal diagnostics")) {
                    Task { try? await store.revealTranscriptionDiagnostics(job.id) }
                }
                .buttonStyle(.borderless)
            }
            .padding(AppTheme.Spacing.mdLg)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
    }

    private func configuration(_ job: WorkbenchTranscriptionJob) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            recognitionCard(job)
            subtitleFlowCard(job)
        }
    }

    private func recognitionCard(_ job: WorkbenchTranscriptionJob) -> some View {
        GroupBox(L10n.string("Recognition")) {
            VStack(spacing: AppTheme.Spacing.mdLg) {
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("Language", selection: languageBinding(job.id)) {
                        ForEach(WorkbenchTranscriptionLanguage.allCases) { option in
                            if option == .english { Divider() }
                            Text(L10n.string(key: option.label)).tag(option.languageCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: AppTheme.zoomed(150))
                }
                HStack {
                    Text("Speakers")
                    Spacer()
                    Picker("Speakers", selection: speakerBinding(job.id)) {
                        ForEach(SpeakerCountOption.allCases) { option in
                            Text(L10n.string(key: option.label)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: AppTheme.zoomed(220))
                }
                HStack(alignment: .top) {
                    Image(systemName: job.compute == .local ? "lock.shield.fill" : "icloud")
                        .foregroundStyle(job.compute == .local ? AppTheme.Status.successColor : Color.indigo)
                    Text(recognitionPrivacyCopy(for: job))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer()
                }
            }
            .padding(.top, AppTheme.Spacing.smMd)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func recognitionPrivacyCopy(for job: WorkbenchTranscriptionJob) -> String {
        L10n.format(
            "%@: %@ · %@: %@",
            L10n.string(TaskPlacementCopy.keepSessionTitle),
            L10n.string(key: job.storage.label),
            L10n.string(TaskPlacementCopy.processWithTitle),
            L10n.string(key: job.compute.label)
        )
    }

    private func subtitleFlowCard(_ job: WorkbenchTranscriptionJob) -> some View {
        GroupBox(L10n.string("Subtitle flow")) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Toggle(
                        L10n.string("Segment subtitles"),
                        isOn: subtitleProcessingBinding(job.id)
                    )
                    .disabled(job.normalizedTargetLanguageCode != nil)
                    SubtitleSegmentationInfoButton(compute: job.compute)
                }

                if job.normalizedTargetLanguageCode != nil {
                    Text(L10n.string("Translation includes subtitle cleanup and segmentation so timing and speaker boundaries stay aligned."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                HStack {
                    Text("Translate to")
                    Spacer()
                    Picker("Translate to", selection: targetLanguageBinding(job.id)) {
                        Text("Do not translate").tag("")
                        Divider()
                        ForEach(WorkbenchTranscriptionLanguage.allCases.filter {
                            $0.languageCode != nil
                        }) { option in
                            Text(L10n.string(key: option.label)).tag(option.languageCode ?? "")
                        }
                    }
                    .labelsHidden()
                    .frame(width: AppTheme.zoomed(180))
                }

                HStack(alignment: .center, spacing: AppTheme.Spacing.smMd) {
                    let useCase: LLMUseCase = job.normalizedTargetLanguageCode == nil
                        ? .subtitleProcessing
                        : .translation
                    let usesCloudSubtitles = job.compute == .cloud && useCase == .subtitleProcessing
                    let usesLocalCaptions = job.compute == .local && useCase == .subtitleProcessing
                        && llmSettings.subtitleSegmentationMethod(connectionStates: connections.states) == .localCaptions
                    let isConfigured = usesCloudSubtitles || usesLocalCaptions || llmSettings.hasUsableModel(for: useCase)
                    Image(systemName: usesCloudSubtitles ? "cloud" : usesLocalCaptions ? "desktopcomputer" : isConfigured ? "checkmark.shield.fill" : "key.slash")
                        .foregroundStyle(
                            isConfigured
                                ? AppTheme.Status.successColor
                                : AppTheme.Status.warningColor
                        )
                    Text(usesCloudSubtitles
                        ? L10n.string("VoxStudio Cloud")
                        : usesLocalCaptions
                            ? L10n.string("Local captions · No API key required")
                            : isConfigured
                                ? llmRouteDescription(for: useCase)
                                : L10n.string("An API key is required only for enabled AI steps."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                    Spacer()
                    Button(L10n.string("AI Settings…")) {
                        SettingsWindowController.shared.show(tab: .ai)
                    }
                    .buttonStyle(.borderless)
                }

                if job.result != nil,
                   !(job.targetLanguageCode ?? "").isEmpty {
                    HStack {
                        Text(L10n.string("Existing transcript can be translated without repeating ASR."))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer()
                        Button(L10n.string("Translate")) {
                            store.runTranslation(job.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(job.state.isActive)
                    }
                }
            }
            .padding(.top, AppTheme.Spacing.smMd)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func processingState(_ job: WorkbenchTranscriptionJob) -> some View {
        if job.state.isActive {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack {
                    HStack(spacing: AppTheme.zoomed(7)) {
                        if let stage = job.flowProgressStage {
                            Text(L10n.string(key: stage.title).uppercased())
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        } else if let stage = job.progressStage {
                            Text(L10n.string(key: stage.title).uppercased())
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        Text(L10n.display(job.progressMessage))
                    }
                    Spacer()
                    Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .font(.system(size: AppTheme.FontSize.sm))
                ProgressView(value: job.progress)
            }
        }

        if let error = job.errorMessage {
            Label(L10n.display(error), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
                .padding(AppTheme.Spacing.mdLg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Status.errorColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }

        if job.state == .completed,
           job.resolvedCloudSyncState == .pending {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label(
                    L10n.display(job.pendingCloudSyncError ?? "The local result has not been saved to VoxStudio Cloud."),
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.warningColor)
                Button(L10n.string("Retry cloud sync")) {
                    store.retryTranscriptionCloudSync(job.id)
                }
                .buttonStyle(.borderless)
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Status.warningColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
    }

    private func transcriptEditor(_ job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack {
                Text(job.currentTrack == .translation ? L10n.string("Translation") : L10n.string("Transcript"))
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                if job.translationTrack != nil {
                    Picker(L10n.string("Track"), selection: selectedTrackBinding(job.id)) {
                        Text(L10n.string("Source")).tag(WorkbenchTranscriptTrack.source)
                        Text(L10n.string("Translation")).tag(WorkbenchTranscriptTrack.translation)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: AppTheme.zoomed(190))
                }
                if let result = job.displayedResult {
                    Text(L10n.format("%@ timed words", result.words.count))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            if job.currentTrack == .translation, job.translationTrack != nil {
                ScrollView {
                    Text(job.displayedText)
                        .font(.system(size: AppTheme.FontSize.md, design: .rounded))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(AppTheme.Spacing.md)
                }
                .frame(minHeight: AppTheme.zoomed(220))
                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                )
            } else if job.result != nil {
                TextEditor(text: transcriptTextBinding(job.id))
                    .font(.system(size: AppTheme.FontSize.md, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(AppTheme.Spacing.md)
                    .frame(minHeight: AppTheme.zoomed(220))
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
            } else {
                VStack(spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: AppTheme.FontSize.title1, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text("Your editable transcript will appear here")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .frame(maxWidth: .infinity, minHeight: AppTheme.zoomed(220))
                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func timeline(_ job: WorkbenchTranscriptionJob) -> some View {
        let segments = job.displayedSegments
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Timed segments")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                if !job.speakerLabels.isEmpty {
                    Text(L10n.format("%@ speakers", job.speakerLabels.count))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .padding(AppTheme.Spacing.lg)
            Divider()
            if !segments.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack {
                            Menu {
                                ForEach(job.speakerLabels, id: \.self) { speaker in
                                    Button {
                                        store.assignSpeaker(
                                            speaker,
                                            from: segment.start,
                                            to: segment.end,
                                            inTranscription: job.id
                                        )
                                    } label: {
                                        Label(
                                            speaker,
                                            systemImage: speaker == segment.speaker
                                                ? "checkmark"
                                                : "person"
                                        )
                                    }
                                }
                                if !job.speakerLabels.isEmpty {
                                    Divider()
                                }
                                Button {
                                    speakerEditRequest = SpeakerEditRequest(
                                        jobID: job.id,
                                        action: .add(start: segment.start, end: segment.end)
                                    )
                                } label: {
                                    Label(L10n.string("Add Speaker…"), systemImage: "person.badge.plus")
                                }
                            } label: {
                                HStack(spacing: AppTheme.Spacing.xxs) {
                                    Text(segment.speaker ?? L10n.string("Speech"))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: AppTheme.FontSize.micro))
                                }
                                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                                .foregroundStyle(speakerColor(segment.speaker))
                            }
                            .menuStyle(.borderlessButton)
                            .help(L10n.string("Assign a speaker to this segment"))

                            if let speaker = segment.speaker {
                                Button {
                                    speakerEditRequest = SpeakerEditRequest(
                                        jobID: job.id,
                                        action: .rename(speaker)
                                    )
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .help(L10n.format("Rename %@ in the full transcript", speaker))
                                .accessibilityLabel(L10n.format("Rename %@", speaker))
                            }
                            Spacer()
                            Text("\(formatTime(segment.start)) – \(formatTime(segment.end))")
                                .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        Text(segment.text)
                            .font(.system(size: AppTheme.FontSize.smMd))
                            .textSelection(.enabled)
                    }
                            .padding(.vertical, AppTheme.Spacing.md)
                            .padding(.horizontal, AppTheme.Spacing.mdLg)
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text("Word-aligned segments appear here")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.Background.surfaceColor.opacity(0.45))
    }

    private func commitSpeakerEdit(_ request: SpeakerEditRequest, name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        switch request.action {
        case .add(let start, let end):
            store.assignSpeaker(
                normalized,
                from: start,
                to: end,
                inTranscription: request.jobID
            )
        case .rename(let current):
            store.renameSpeaker(current, to: normalized, inTranscription: request.jobID)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if let message = store.transcriptionAdmissionError {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Status.warningColor)
                        Text(L10n.display(message))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Spacer()
                        Button("Dismiss") { store.clearTranscriptionAdmissionError() }
                            .buttonStyle(.borderless)
                    }
                    .padding(AppTheme.Spacing.mdLg)
                    .background(AppTheme.Status.warningColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                }
                transcriptionEntryBar
                if entryMode == .record {
                    entryHero
                        .padding(AppTheme.Spacing.xlXxl)
                        .background(
                            LinearGradient(
                                colors: [AppTheme.Background.surfaceColor, AppTheme.Background.raisedColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                        }
                } else {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                        entryHero
                            .frame(maxWidth: .infinity, alignment: .leading)

                        quickStartCard
                            .frame(width: AppTheme.zoomed(300))
                    }
                    .padding(AppTheme.Spacing.xlXxl)
                    .background(
                        LinearGradient(
                            colors: [AppTheme.Background.surfaceColor, AppTheme.Background.raisedColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    )
                    .overlay {
                        if entryMode != .netVideo {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                        }
                    }

                }

                WorkbenchRecentTranscriptSessionsSection(
                    modeTitle: recentSessionsTitle,
                    onChooseMedia: entryMode == .importFiles ? { importMedia() } : nil
                )
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transcriptionEntryBar: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string("TRANSCRIPTION ENTRY"))
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.mutedColor)
            entryModeButton(L10n.string("Import files"), systemImage: "square.and.arrow.down", active: entryMode == .importFiles) {
                entryMode = .importFiles
            }
            entryModeButton(L10n.string("Net video"), systemImage: "video", active: entryMode == .netVideo) {
                entryMode = .netVideo
            }
            entryModeButton(L10n.string("Record"), systemImage: "video.circle", active: entryMode == .record) {
                entryMode = .record
            }
            Spacer(minLength: AppTheme.Spacing.md)
            if entryMode != .record {
                Text(entryBarCaption)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            if entryMode != .netVideo {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
        }
    }

    @ViewBuilder
    private func entryModeButton(
        _ title: String,
        systemImage: String,
        active: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if active {
            Button(action: action) {
                entryModeLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
        } else {
            Button(action: action) {
                entryModeLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
        }
    }

    private func entryModeLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var entryBarCaption: String {
        switch entryMode {
        case .netVideo:
            netVideoKind == .video
                ? L10n.string("Paste a YouTube link, download video to this Mac, then transcribe")
                : L10n.string("Paste a YouTube link, download audio to this Mac, then transcribe")
        case .record:
            L10n.string("Record this Mac, then transcribe the local file")
        case .importFiles:
            L10n.string("Fastest path from local files to a structured transcript workspace")
        }
    }

    private var recentSessionsTitle: String {
        switch entryMode {
        case .netVideo: L10n.string("Net Video")
        case .record: L10n.string("Record")
        case .importFiles: L10n.string("Import Files")
        }
    }

    @ViewBuilder
    private var entryHero: some View {
        switch entryMode {
        case .netVideo:
            netVideoHero
        case .record:
            RecordWorkbenchPanel(session: recording)
        case .importFiles:
            importFilesHero
        }
    }

    private var importFilesHero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("BEST FOR MEETINGS AND INTERVIEWS"), systemImage: "sparkles")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Accent.link)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Capsule())
            Text(L10n.string("Import audio or video and turn it into a searchable transcript workspace."))
                .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("Choose files, confirm processing options, then watch local progress before the session workspace opens."))
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
                Button(L10n.string("Choose media")) { importMedia() }
                    .buttonStyle(.borderedProminent)
                Text(L10n.string("Supports multiple audio and video files · processed one at a time"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private var netVideoHero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("BEST FOR PUBLIC TALKS, INTERVIEWS, AND PUBLISHED VIDEO"), systemImage: "sparkles")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Accent.link)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Capsule())
            Text(L10n.string("Paste a public YouTube link and turn published content into editable text."))
                .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(netVideoKind == .video
                ? L10n.string("The full video is downloaded on this Mac with its audio track. 1080p is the default when that tier exists. Local YouTubeKit runs first; the author's remote server is only used if local extraction fails.")
                : L10n.string("The full audio track is downloaded on this Mac. Local YouTubeKit runs first; the author's remote server is only used if local extraction fails. Video is not downloaded."))
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Paste a public YouTube URL"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                TextField("https://www.youtube.com/watch?v=…", text: $netVideoURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.md))
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .frame(height: AppTheme.zoomed(44))
                    .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.soft), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(
                                netVideoURLIsInvalid ? AppTheme.Status.errorColor : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
                    .disabled(netVideoPhase.isInProgress)
                    .onSubmit { extractNetVideo() }
                    .onChange(of: netVideoURL) { _, _ in
                        resetVideoQualities()
                        if showVideoQualityAdvanced, netVideoKind == .video {
                            loadVideoQualities()
                        }
                    }
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("YouTube")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(AppTheme.Background.raisedColor, in: Capsule())
                    Spacer()
                }
                if netVideoURLIsInvalid {
                    Text(L10n.string("Paste a public YouTube watch, Shorts, or youtu.be URL."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }

            netVideoKindPicker

            if netVideoKind == .video, YouTubeURL.isSupported(netVideoURL) {
                videoQualityAdvanced
            }

            netVideoDownloadAction
        }
    }

    private var netVideoDownloadAction: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
                if netVideoPhase.isInProgress {
                    netVideoActionLabel
                } else {
                    Button { extractNetVideo() } label: { netVideoActionLabel }
                        .buttonStyle(.plain)
                        .disabled(!canExtractNetVideo)
                        .onHover { netVideoActionHovered = $0 }
                        .animation(.easeOut(duration: 0.18), value: netVideoActionHovered)
                        .accessibilityHint(L10n.string("Downloads the selected media, then opens transcription options."))
                }

                if netVideoPhase.isInProgress {
                    Button(L10n.string("Cancel"), role: .cancel) {
                        netVideoTask?.cancel()
                        netVideoTask = nil
                        netVideoImportID = nil
                        netVideoPhase = .idle
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }

            if netVideoPhase.isInProgress {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(netVideoPhase.statusText(kind: netVideoKind))
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                    if let fraction = netVideoPhase.downloadFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(AppTheme.Accent.link)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(AppTheme.Accent.link)
                    }
                }
                .frame(maxWidth: AppTheme.zoomed(460), alignment: .leading)
            } else if case .failed(let message) = netVideoPhase {
                Label(L10n.display(message), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else {
                Label(
                    YouTubeURL.isSupported(netVideoURL)
                        ? L10n.string("Next: confirm processing options, then start transcription.")
                        : L10n.string("Paste a YouTube link to enable download."),
                    systemImage: YouTubeURL.isSupported(netVideoURL) ? "checkmark.circle.fill" : "link"
                )
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var netVideoActionLabel: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                .frame(width: AppTheme.zoomed(42), height: AppTheme.zoomed(42))
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(netVideoPhase.isInProgress
                    ? L10n.string("Download in progress…")
                    : netVideoKind == .video
                        ? L10n.string("Download video to this Mac")
                        : L10n.string("Download audio to this Mac"))
                    .font(.system(size: AppTheme.FontSize.md, weight: .bold))
                Text(netVideoPhase.isInProgress
                    ? L10n.string("Preparing your file for transcription")
                    : L10n.string("Then choose transcription options"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .opacity(0.85)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if netVideoPhase.isInProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .frame(width: AppTheme.zoomed(30), height: AppTheme.zoomed(30))
                    .background(.white.opacity(0.18), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(AppTheme.Spacing.md)
        .frame(minWidth: AppTheme.zoomed(360), maxWidth: AppTheme.zoomed(460), alignment: .leading)
        .background(
            LinearGradient(
                colors: YouTubeURL.isSupported(netVideoURL)
                    ? [Color(red: 0.13, green: 0.44, blue: 0.88), Color(red: 0.22, green: 0.32, blue: 0.73)]
                    : [Color(red: 0.40, green: 0.52, blue: 0.69), Color(red: 0.35, green: 0.44, blue: 0.59)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
        )
        .shadow(
            color: AppTheme.Accent.link.opacity(canExtractNetVideo ? (netVideoActionHovered ? 0.30 : 0.18) : 0.07),
            radius: AppTheme.zoomed(netVideoActionHovered ? 16 : 10),
            y: AppTheme.zoomed(5)
        )
        .scaleEffect(netVideoActionHovered && canExtractNetVideo ? 1.012 : 1)
    }

    private var quickStartCard: some View {
        let steps: [String]
        let title: String
        let icon: String
        switch entryMode {
        case .netVideo:
            steps = netVideoKind == .video
                ? ["Paste a public YouTube link", "Download video to this Mac", "Confirm processing options"]
                : ["Paste a public YouTube link", "Download audio to this Mac", "Confirm processing options"]
            title = "Net video"
            icon = "link"
        case .record:
            steps = ["Choose audio sources", "Record, then stop from the menu bar", "Confirm processing options"]
            title = "Record"
            icon = "record.circle"
        case .importFiles:
            steps = ["Choose one or more local files", "Confirm processing options", "Continue editing in the workspace"]
            title = "Import files"
            icon = "square.and.arrow.down"
        }
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Label("QUICK START", systemImage: icon)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Accent.link)
            Text(L10n.string(key: title))
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    Text("\(index + 1)")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft), in: Circle())
                    Text(L10n.string(key: title))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            if entryMode != .netVideo {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
        }
    }

    private var netVideoKindPicker: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            netVideoKindCard(
                kind: .audio,
                title: "Audio",
                detail: "Smaller and faster. Transcript only.",
                systemImage: "waveform"
            )
            netVideoKindCard(
                kind: .video,
                title: "Video",
                detail: "Local mp4 with picture and sound. Default 1080p.",
                systemImage: "film"
            )
        }
    }

    private func netVideoKindCard(
        kind: NetVideoExtractKind,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        let selected = netVideoKind == kind
        return Button {
            netVideoKind = kind
            if kind == .video, showVideoQualityAdvanced,
               videoQualities.isEmpty, !videoQualityLoading {
                loadVideoQualities()
            }
        } label: {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(selected ? AppTheme.Accent.link : AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(L10n.string(title))
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AppTheme.Accent.link : AppTheme.Text.mutedColor)
                    }
                    Text(L10n.string(detail))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AppTheme.Accent.link.opacity(AppTheme.Opacity.soft) : AppTheme.Background.surfaceColor,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
            )
        }
        .buttonStyle(.plain)
        .disabled(netVideoPhase.isInProgress)
    }

    private var videoQualityAdvanced: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Button {
                showVideoQualityAdvanced.toggle()
                if showVideoQualityAdvanced {
                    loadVideoQualities()
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Advanced"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    Text(videoQualitySummary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                    Image(systemName: showVideoQualityAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(netVideoPhase.isInProgress)

            if showVideoQualityAdvanced {
                if videoQualityLoading {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Checking available quality…"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                } else if let videoQualityError {
                    Text(L10n.display(videoQualityError))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                } else if videoQualities.isEmpty {
                    Text(L10n.string("Open Advanced to load the quality options for this video."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(videoQualities, id: \.self) { resolution in
                                videoQualityButton(resolution)
                            }
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.soft), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    private var videoQualitySummary: String {
        guard let resolution = selectedVideoResolution ?? defaultVideoResolution else {
            return L10n.string("Auto · up to 1080p")
        }
        if resolution == defaultVideoResolution || selectedVideoResolution == nil {
            return L10n.string("\(resolution)p · Default")
        }
        return "\(resolution)p"
    }

    private func videoQualityButton(_ resolution: Int) -> some View {
        let selected = (selectedVideoResolution ?? defaultVideoResolution) == resolution
        let isDefault = resolution == defaultVideoResolution
        return Button {
            selectedVideoResolution = resolution
        } label: {
            VStack(spacing: AppTheme.Spacing.xxs) {
                Text("\(resolution)p")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                if isDefault {
                    Text(L10n.string("Default"))
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .foregroundStyle(selected ? Color.white : AppTheme.Text.primaryColor)
            .background(selected ? AppTheme.Accent.link : AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(netVideoPhase.isInProgress)
    }

    private var netVideoInitialOptions: LocalProcessingOptions? {
        guard pendingNetVideoTitle != nil else { return nil }
        return LocalProcessingOptions(
            customTitle: pendingNetVideoTitle
        )
    }

    private var netVideoURLIsInvalid: Bool {
        let trimmed = netVideoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !YouTubeURL.isSupported(trimmed)
    }

    private var canExtractNetVideo: Bool {
        YouTubeURL.isSupported(netVideoURL) && !netVideoPhase.isInProgress
    }

    private func resetVideoQualities() {
        videoQualityTask?.cancel()
        videoQualityTask = nil
        videoQualities = []
        selectedVideoResolution = nil
        defaultVideoResolution = nil
        videoQualityLoading = false
        videoQualityError = nil
    }

    private func loadVideoQualities() {
        let raw = netVideoURL
        guard YouTubeURL.isSupported(raw) else { return }
        videoQualityTask?.cancel()
        videoQualityLoading = true
        videoQualityError = nil
        videoQualityTask = Task {
            do {
                let list = try await YouTubeAudioImporter.listVideoQualities(from: raw)
                guard !Task.isCancelled else { return }
                videoQualities = list.resolutions
                defaultVideoResolution = list.defaultResolution
                if let selected = selectedVideoResolution, list.resolutions.contains(selected) {
                    selectedVideoResolution = selected
                } else {
                    selectedVideoResolution = list.defaultResolution
                }
                videoQualityLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                videoQualityLoading = false
                videoQualityError = error.localizedDescription
            }
        }
    }

    private func importMedia() {
        pendingNetVideoTitle = nil
        Task {
            do {
                try await AccountService.shared.prepareNewContentAccess()
                let urls = await WorkbenchFilePicker.pickMediaFiles()
                if !urls.isEmpty {
                    store.stageMediaImport(urls)
                }
                } catch is AppAccessError {
                    return
                } catch {
                    store.transcriptionAdmissionError = error.localizedDescription
            }
        }
    }

    private func extractNetVideo() {
        let raw = netVideoURL
        guard YouTubeURL.isSupported(raw) else {
            netVideoPhase = .failed("Paste a public YouTube watch, Shorts, or youtu.be URL.")
            return
        }
        guard !netVideoPhase.isInProgress else { return }
        netVideoTask?.cancel()
        let kind = netVideoKind
        let resolution = selectedVideoResolution
        let importID = UUID()
        netVideoImportID = importID
        netVideoPhase = .extractingLocal
        netVideoTask = Task {
            var importedURL: URL?
            do {
                try await AccountService.shared.prepareNewContentAccess()
                guard netVideoImportID == importID else { throw CancellationError() }
                let result: YouTubeAudioImportResult
                if kind == .video {
                    result = try await YouTubeAudioImporter.importVideo(
                        from: raw,
                        into: WorkbenchStore.netVideoMediaDirectory,
                        resolution: resolution
                    ) { progress in
                        Task { @MainActor in
                            guard netVideoImportID == importID else { return }
                            netVideoPhase = Self.phase(for: progress)
                        }
                    }
                } else {
                    result = try await YouTubeAudioImporter.importAudio(
                        from: raw,
                        into: WorkbenchStore.netVideoMediaDirectory
                    ) { progress in
                        Task { @MainActor in
                            guard netVideoImportID == importID else { return }
                            netVideoPhase = Self.phase(for: progress)
                        }
                    }
                }
                importedURL = result.fileURL
                try Task.checkCancellation()
                guard netVideoImportID == importID else { throw CancellationError() }
                pendingNetVideoTitle = result.title
                netVideoPhase = .idle
                let sourceURL = URL(string: "https://www.youtube.com/watch?v=\(result.videoID)")!
                store.stageNetVideoImport(
                    mediaURL: result.fileURL,
                    sourceURL: sourceURL,
                    videoID: result.videoID,
                    title: result.title
                )
                netVideoImportID = nil
                netVideoTask = nil
            } catch is CancellationError {
                if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
                if netVideoImportID == importID {
                    netVideoPhase = .idle
                    netVideoImportID = nil
                    netVideoTask = nil
                }
            } catch is AppAccessError {
                if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
                if netVideoImportID == importID {
                    netVideoPhase = .idle
                    netVideoImportID = nil
                    netVideoTask = nil
                }
            } catch {
                if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
                if netVideoImportID == importID {
                    netVideoPhase = .failed(error.localizedDescription)
                    netVideoImportID = nil
                    netVideoTask = nil
                }
            }
        }
    }

    private func start(_ job: WorkbenchTranscriptionJob) {
        Task {
            _ = await llmSettings.credentialAvailable()
            if TranscriptionAIAccessPromptPolicy.shouldPresent(
                compute: job.compute,
                hasUsableLLM: llmSettings.hasUsableModel(for: .subtitleProcessing)
            ) {
                pendingBasicStart = PendingBasicTranscriptionStart(jobID: job.id)
            } else {
                store.runTranscription(job.id)
            }
        }
    }

    private func sendToEditor(_ job: WorkbenchTranscriptionJob) {
        openingInEditorID = job.id
        store.updateTranscription(job.id) { $0.errorMessage = nil }
        Task {
            defer { openingInEditorID = nil }
            do {
                try await WorkbenchEditorBridge.openTranscript(job)
            } catch {
                store.updateTranscription(job.id) {
                    $0.errorMessage = "Could not open the captioned project: \(error.localizedDescription)"
                }
            }
        }
    }

    private func languageBinding(_ id: UUID) -> Binding<String?> {
        Binding(
            get: { store.transcriptions.first { $0.id == id }?.languageCode },
            set: { value in store.updateTranscription(id) { $0.languageCode = value } }
        )
    }

    private func speakerBinding(_ id: UUID) -> Binding<SpeakerCountOption> {
        Binding(
            get: { store.transcriptions.first { $0.id == id }?.speakerCount ?? .auto },
            set: { value in store.updateTranscription(id) { $0.speakerCount = value } }
        )
    }

    private func subtitleProcessingBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard let job = store.transcriptions.first(where: { $0.id == id }) else {
                    return false
                }
                return job.normalizedTargetLanguageCode != nil
                    || job.shouldProcessSubtitles
            },
            set: { value in
                store.updateTranscription(id) { $0.useLLMSubtitleProcessing = value }
            }
        )
    }

    private func targetLanguageBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.transcriptions.first { $0.id == id }?.targetLanguageCode ?? "" },
            set: { value in
                store.updateTranscription(id) {
                    $0.targetLanguageCode = value.isEmpty ? nil : value
                }
            }
        )
    }

    private func selectedTrackBinding(_ id: UUID) -> Binding<WorkbenchTranscriptTrack> {
        Binding(
            get: {
                store.transcriptions.first { $0.id == id }?.currentTrack ?? .source
            },
            set: { value in
                store.updateTranscription(id) { $0.selectedTrack = value }
            }
        )
    }

    private func transcriptTextBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.transcriptions.first { $0.id == id }?.editedText ?? "" },
            set: { value in store.updateTranscription(id) { $0.editedText = value } }
        )
    }

    private func primaryActionLabel(_ job: WorkbenchTranscriptionJob) -> String {
        let prefix = job.state == .completed ? "Run again" : "Run"
        if job.targetLanguageCode != nil,
           llmSettings.hasUsableModel(for: .subtitleProcessing),
           llmSettings.hasUsableModel(for: .translation) {
            return "\(prefix): transcribe + translate"
        }
        if job.shouldProcessSubtitles {
            return "\(prefix): transcribe + subtitles"
        }
        return job.state == .completed ? "Re-transcribe" : "Transcribe"
    }

    private func llmRouteDescription(for useCase: LLMUseCase) -> String {
        switch AITransportPolicy.current {
        case .hosted:
            return L10n.string("Voxella AI (server-managed)")
        case .byok:
            let chain = llmSettings.route(for: useCase).modelChain
            return chain.isEmpty ? L10n.string("Not configured") : chain.joined(separator: " → ")
        case .unavailable:
            return L10n.string("Not configured")
        }
    }

    private func speakerColor(_ speaker: String?) -> Color {
        guard let speaker else { return AppTheme.Text.tertiaryColor }
        let palette: [Color] = [.blue, .purple, .orange, .green]
        return palette[abs(speaker.hashValue) % palette.count]
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remainder)
    }
}

private enum NetVideoExtractKind {
    case audio
    case video
}

private enum TranscriptionEntryMode {
    case importFiles
    case netVideo
    case record
}

private struct PendingBasicTranscriptionStart: Identifiable {
    let jobID: UUID

    var id: UUID { jobID }
}

private enum NetVideoImportPhase: Equatable {
    case idle
    case extractingLocal
    case extractingRemote
    case downloading(YouTubeAudioDownloadProgress)
    case preparing
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .extractingLocal, .extractingRemote, .downloading, .preparing: true
        case .idle, .failed: false
        }
    }

    var downloadFraction: Double? {
        if case .downloading(let snapshot) = self { return snapshot.fraction }
        return nil
    }

    @MainActor func statusText(kind: NetVideoExtractKind) -> String {
        switch self {
        case .idle, .failed:
            return ""
        case .extractingLocal:
            return L10n.string("Finding available media…")
        case .extractingRemote:
            return L10n.string("Trying another download source…")
        case .preparing:
            return L10n.string("Combining video and audio…")
        case .downloading(let snapshot):
            let subject: String
            switch snapshot.component {
            case .videoTrack: subject = L10n.string("Downloading video track · 1 of 2")
            case .audioTrack: subject = L10n.string("Downloading audio track · 2 of 2")
            case nil: subject = kind == .video
                ? L10n.string("Downloading video")
                : L10n.string("Downloading audio")
            }
            if let fraction = snapshot.fraction {
                return L10n.format("%@ · %@%%", subject, Int((fraction * 100).rounded()))
            }
            if snapshot.bytesWritten > 0 {
                let size = ByteCountFormatter.string(fromByteCount: snapshot.bytesWritten, countStyle: .file)
                return L10n.format("%@ · %@ downloaded", subject, size)
            }
            return subject
        }
    }
}

extension TranscribeWorkbenchView {
    fileprivate static func phase(for progress: YouTubeAudioImportProgress) -> NetVideoImportPhase {
        switch progress {
        case .extractingLocal:
            .extractingLocal
        case .extractingRemote:
            .extractingRemote
        case .downloading(let snapshot):
            .downloading(snapshot)
        case .preparing:
            .preparing
        }
    }
}

private struct SpeakerEditRequest: Identifiable {
    enum Action {
        case add(start: Double, end: Double)
        case rename(String)
    }

    let id = UUID()
    let jobID: UUID
    let action: Action

    var title: String {
        switch action {
        case .add: "Add Speaker"
        case .rename: "Rename Speaker"
        }
    }

    var initialName: String {
        switch action {
        case .add: ""
        case .rename(let current): current
        }
    }

    var commitLabel: String {
        switch action {
        case .add: "Add"
        case .rename: "Rename"
        }
    }
}

private struct SpeakerNameEditor: View {
    let request: SpeakerEditRequest
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name: String

    init(request: SpeakerEditRequest, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCommit = onCommit
        _name = State(initialValue: request.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            Text(L10n.string(key: request.title))
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
        TextField(L10n.string("Speaker name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityLabel(L10n.string("Speaker name"))
            HStack(spacing: AppTheme.Spacing.smMd) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string(key: request.commitLabel)) {
                    onCommit(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.ComponentSize.speakerEditorWidth)
        .onAppear { isFocused = true }
    }
}
