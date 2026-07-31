import SwiftUI

struct TranscribeWorkbenchView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared
    @State private var openingInEditorID: UUID?
    @State private var speakerEditRequest: SpeakerEditRequest?

    var body: some View {
        Group {
            if let index = store.selectedTranscriptionIndex {
                detail(index: index)
            } else {
                emptyState
            }
        }
        .background(AppTheme.Background.baseColor)
        .onAppear {
            llmSettings.refreshCredentialStatus()
        }
        .sheet(item: $speakerEditRequest) { request in
            SpeakerNameEditor(request: request) { name in
                commitSpeakerEdit(request, name: name)
            }
        }
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
                    Label("New transcription", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Back to transcription entry")
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL]) }
                    .buttonStyle(.borderless)
                Button {
                    sendToEditor(job)
                } label: {
                    if openingInEditorID == job.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Opening editor…")
                        }
                    } else {
                        Label("Open with captions", systemImage: "captions.bubble")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(job.result == nil || job.state == .running || openingInEditorID != nil)
                if job.state == .running || job.state == .cancelling {
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
            .padding(16)

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        configuration(job)
                        processingState(job)
                        diagnostics(job)
                        transcriptEditor(job)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 520, maxWidth: .infinity)

                Divider()
                timeline(job)
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func diagnostics(_ job: WorkbenchTranscriptionJob) -> some View {
        if let diagnostics = job.diarizationDiagnostics {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.checkmark")
                    .foregroundStyle(AppTheme.Status.successColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostics.backend.title)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    HStack(spacing: 8) {
                        Text("\(diagnostics.detectedSpeakerCount) detected")
                        if let rtf = diagnostics.realTimeFactor {
                            Text("RTF \(rtf.formatted(.number.precision(.fractionLength(2))))")
                        }
                        if diagnostics.processedChunks > 0 {
                            Text("\(diagnostics.processedChunks) chunks")
                        }
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    ForEach(diagnostics.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                }
                Spacer()
                Button("Reveal diagnostics") {
                    Task { try? await store.revealTranscriptionDiagnostics(job.id) }
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
    }

    private func configuration(_ job: WorkbenchTranscriptionJob) -> some View {
        HStack(alignment: .top, spacing: 14) {
            recognitionCard(job)
            subtitleFlowCard(job)
        }
    }

    private func recognitionCard(_ job: WorkbenchTranscriptionJob) -> some View {
        GroupBox("Recognition") {
            VStack(spacing: 12) {
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("Language", selection: languageBinding(job.id)) {
                        ForEach(WorkbenchTranscriptionLanguage.allCases) { option in
                            if option == .english { Divider() }
                            Text(option.label).tag(option.languageCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                HStack {
                    Text("Speakers")
                    Spacer()
                    Picker("Speakers", selection: speakerBinding(job.id)) {
                        ForEach(SpeakerCountOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                HStack(alignment: .top) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(AppTheme.Status.successColor)
                    Text("Audio is decoded and transcribed on this Mac. Only transcript text is sent to the configured LLM when an AI step is enabled.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer()
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func subtitleFlowCard(_ job: WorkbenchTranscriptionJob) -> some View {
        GroupBox("Subtitle flow") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Clean and segment subtitles with the configured LLM",
                    isOn: subtitleProcessingBinding(job.id)
                )
                .disabled(job.normalizedTargetLanguageCode != nil)

                if job.normalizedTargetLanguageCode != nil {
                    Text("Translation includes subtitle cleanup and segmentation so timing and speaker boundaries stay aligned.")
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
                            Text(option.label).tag(option.languageCode ?? "")
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                HStack(alignment: .center, spacing: 8) {
                    let useCase: LLMUseCase = job.normalizedTargetLanguageCode == nil
                        ? .subtitleProcessing
                        : .translation
                    let isConfigured = llmSettings.hasConfiguredModel(for: useCase)
                    Image(systemName: isConfigured ? "checkmark.shield.fill" : "key.slash")
                        .foregroundStyle(
                            isConfigured
                                ? AppTheme.Status.successColor
                                : AppTheme.Status.warningColor
                        )
                    Text(isConfigured
                        ? llmSettings.route(for: useCase).primaryModel
                        : "An API key is required only for enabled AI steps.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                    Spacer()
                    Button("AI Settings…") {
                        SettingsWindowController.shared.show(tab: .ai)
                    }
                    .buttonStyle(.borderless)
                }

                if job.result != nil,
                   !(job.targetLanguageCode ?? "").isEmpty {
                    HStack {
                        Text("Existing transcript can be translated without repeating ASR.")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer()
                        Button("Translate") {
                            store.runTranslation(job.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(job.state == .running || job.state == .cancelling)
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func processingState(_ job: WorkbenchTranscriptionJob) -> some View {
        if !models.hasRequiredTranscriptionModels(
            languageCode: job.languageCode,
            speakerCount: job.speakerCount.count
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(AppTheme.Status.warningColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local speech models are required")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    Text("Whisper, spoken-language detection, word alignment, VAD, and speaker detection are downloaded only when you choose to install them.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Button("Manage Models") { models.presentManager() }
            }
            .padding(12)
            .background(AppTheme.Status.warningColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }

        if job.state == .running || job.state == .cancelling {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 7) {
                        if let stage = job.flowProgressStage {
                            Text(stage.title.uppercased())
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        } else if let stage = job.progressStage {
                            Text(stage.title.uppercased())
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        Text(job.progressMessage)
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
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Status.errorColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
    }

    private func transcriptEditor(_ job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.currentTrack == .translation ? "Translation" : "Transcript")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                if job.translationTrack != nil {
                    Picker("Track", selection: selectedTrackBinding(job.id)) {
                        Text("Source").tag(WorkbenchTranscriptTrack.source)
                        Text("Translation").tag(WorkbenchTranscriptTrack.translation)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                if let result = job.displayedResult {
                    Text("\(result.words.count) timed words")
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
                        .padding(10)
                }
                .frame(minHeight: 220)
                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
                )
            } else if job.result != nil {
                TextEditor(text: transcriptTextBinding(job.id))
                    .font(.system(size: AppTheme.FontSize.md, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 220)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text("Your editable transcript will appear here")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
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
                    Text("\(job.speakerLabels.count) speakers")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .padding(14)
            Divider()
            if !segments.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 6) {
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
                                    Label("Add Speaker…", systemImage: "person.badge.plus")
                                }
                            } label: {
                                HStack(spacing: AppTheme.Spacing.xxs) {
                                    Text(segment.speaker ?? "Speech")
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: AppTheme.FontSize.micro))
                                }
                                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                                .foregroundStyle(speakerColor(segment.speaker))
                            }
                            .menuStyle(.borderlessButton)
                            .help("Assign a speaker to this segment")

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
                                .help("Rename \(speaker) in the full transcript")
                                .accessibilityLabel("Rename \(speaker)")
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
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 28, weight: .light))
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
                transcriptionEntryBar
                HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        Label("BEST FOR MEETINGS AND INTERVIEWS", systemImage: "sparkles")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                            .foregroundStyle(AppTheme.Accent.link)
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Capsule())
                        Text("Upload audio or video and turn it into a searchable transcript workspace.")
                            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Processing starts locally after upload, with word timestamps, speaker labels, subtitle cleanup, and editor captions available from the same workspace.")
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
                            Button("Choose media") { importMedia() }
                                .buttonStyle(.borderedProminent)
                            Text("Supports common audio and video files")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    quickStartCard
                        .frame(width: 300)
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
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                }

                HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                    guidanceCard(
                        eyebrow: "BEST FIT",
                        title: "When upload is the best choice",
                        detail: "You already have a local source file and want the shortest path to transcript, translation, or export.",
                        systemImage: "wand.and.stars"
                    )
                    guidanceCard(
                        eyebrow: "AFTER START",
                        title: "Keep the workflow moving",
                        detail: "Once a session is created, edit, translate, export, and prepare a dub without leaving this workspace.",
                        systemImage: "arrow.up.circle"
                    )
                }

                WorkbenchRecentTranscriptSessionsSection(
                    modeTitle: "Upload Files",
                    onChooseMedia: { importMedia() }
                )
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transcriptionEntryBar: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Text("TRANSCRIPTION ENTRY")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.mutedColor)
            entryModeButton("Upload files", systemImage: "arrow.up.circle", active: true) { importMedia() }
            entryModeButton("Net video", systemImage: "video", active: false, action: {})
            entryModeButton("Record", systemImage: "video.circle", active: false, action: {})
            entryModeButton("Live", systemImage: "dot.radiowaves.left.and.right", active: false, action: {})
            Spacer(minLength: AppTheme.Spacing.md)
            Text("Fastest path from local files to a structured transcript workspace")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    @ViewBuilder
    private func entryModeButton(
        _ title: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if active {
            Button(action: action) {
                entryModeLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                entryModeLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(true)
        }
    }

    private func entryModeLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var quickStartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Label("QUICK START", systemImage: "rectangle.and.arrow.up")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Accent.link)
            Text("Upload files")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            ForEach(Array(["Choose one or more local files", "Confirm processing options", "Continue editing in the workspace"].enumerated()), id: \.offset) { index, title in
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    Text("\(index + 1)")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft), in: Circle())
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Divider()
            Text("LOCAL PROCESSING")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("\(models.descriptor(for: models.activeASRModelID).title) · word timestamps · up to 4 speakers")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(AppTheme.Spacing.lgXl)
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func guidanceCard(
        eyebrow: String,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Label(eyebrow, systemImage: systemImage)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(title)
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            Text(detail)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func importMedia() {
        Task {
            if let url = await WorkbenchFilePicker.pickMedia() {
                store.addTranscription(sourceURL: url)
            }
        }
    }

    private func start(_ job: WorkbenchTranscriptionJob) {
        guard models.hasRequiredTranscriptionModels(
            languageCode: job.languageCode,
            speakerCount: job.speakerCount.count
        ) else {
            models.presentManager()
            return
        }
        store.runTranscription(job.id)
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
                    || job.shouldProcessSubtitles(
                        hasAPIKey: llmSettings.hasConfiguredModel(for: .subtitleProcessing)
                    )
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
        if job.targetLanguageCode != nil { return "\(prefix): transcribe + translate" }
        if job.shouldProcessSubtitles(
            hasAPIKey: llmSettings.hasConfiguredModel(for: .subtitleProcessing)
        ) {
            return "\(prefix): transcribe + subtitles"
        }
        return job.state == .completed ? "Transcribe again" : "Transcribe"
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
            Text(request.title)
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityLabel("Speaker name")
            HStack(spacing: AppTheme.Spacing.smMd) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.commitLabel) {
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
