import AppKit
import SwiftUI

/// Dub creation workspace aligned with `voxella-web` `DubPanel.tsx`.
struct DubWorkbenchView: View {
    @Bindable private var store = WorkbenchStore.shared
    @State private var rewriteSegmentIndex: Int?
    @State private var showProcessingOptions = false

    var body: some View {
        Group {
            if let index = store.selectedDubIndex {
                builder(index: index)
                    .id(store.dubs[index].id)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.Background.baseColor)
        .onAppear {
            store.ensureActiveDubDraft()
        }
    }

    private func builder(index: Int) -> some View {
        let job = store.dubs[index]
        let segments = job.segments ?? []
        let totalSeconds = segments.reduce(0) { partial, segment in
            partial + estimateDurationSeconds(segment.text, language: job.language)
        }

        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    headerCard(job)
                    ForEach(Array(segments.enumerated()), id: \.element.index) { displayIndex, segment in
                        segmentCard(job: job, displayIndex: displayIndex, segment: segment)
                    }
                    addSegmentButton(job.id)
                    if job.state.isActive {
                        progressCard(job)
                    }
                    if let error = job.errorMessage {
                        Label(L10n.display(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Status.errorColor)
                    }
                    if job.resolvedCloudSyncState == .pending {
                        Button(L10n.string("Retry cloud sync")) {
                            store.retryDubCloudSync(job.id)
                        }
                        .buttonStyle(.borderless)
                    }
                    if let output = job.outputURL {
                        outputCard(output: output)
                    }
                    WorkbenchRecentDubSessionsSection()
                    Color.clear.frame(height: AppTheme.zoomed(88))
                }
                .padding(AppTheme.Spacing.xxl)
                .frame(maxWidth: AppTheme.Workbench.composerMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            generateBar(job: job, segmentCount: segments.count, totalSeconds: totalSeconds)
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.bottom, AppTheme.Spacing.lg)
        }
        .sheet(item: Binding(
            get: { rewriteSegmentIndex.map(DubRewriteTarget.init(segmentIndex:)) },
            set: { rewriteSegmentIndex = $0?.segmentIndex }
        )) { target in
            DubRewriteSheet(jobID: job.id, segmentIndex: target.segmentIndex) {
                rewriteSegmentIndex = nil
            }
            .appZoomEnvironment(presentationBoundary: true)
        }
        .sheet(isPresented: $showProcessingOptions) {
            if let current = store.dubs.first(where: { $0.id == job.id }) {
                DubProcessingOptionsSheet(
                    job: current,
                    onPrepareCloud: { placement in
                        await store.prepareCloudAccess(for: placement)
                    },
                    onCancel: { showProcessingOptions = false },
                    onContinue: { submission in
                        continueGeneration(jobID: job.id, placement: submission.placement)
                    }
                )
                .appZoomEnvironment(presentationBoundary: true)
            } else {
                ProgressView()
                    .frame(width: AppTheme.zoomed(620), height: AppTheme.zoomed(610))
            }
        }
    }

    private func headerCard(_ job: WorkbenchDubJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                fieldColumn(title: L10n.string("Voiceover language")) {
                    Picker(L10n.string("Language"), selection: languageBinding(job.id)) {
                        ForEach(WorkbenchDubLanguage.allCases.filter { $0 != .automatic }) { language in
                            Text(L10n.string(key: language.label)).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                fieldColumn(title: L10n.string("Task name")) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        TextField(
                            L10n.string(key: SessionTitlePolicy.autoGeneratePlaceholder),
                            text: titleBinding(job.id)
                        )
                        .textFieldStyle(.roundedBorder)
                        InlineVoiceInputControl(text: titleBinding(job.id), multiline: false)
                    }
                }

                fieldColumn(title: L10n.string("Reference voice")) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        VoiceReferencePicker(
                            selection: referenceVoiceBinding(job.id),
                            languageCode: job.language,
                            defaultLabel: L10n.string("Select a reference voice…")
                        )
                        Button {
                            SettingsWindowController.shared.show(tab: .voiceLibrary)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("Manage reference voices"))
                    }
                }
            }

            HStack {
                Menu(L10n.string("Import from transcript")) {
                    ForEach(store.transcriptions.filter { $0.result != nil }) { transcript in
                        Menu(transcript.sessionTitle) {
                            Button(L10n.string("Source track")) {
                                store.useTranscript(transcript.id, forDub: job.id, track: .source)
                            }
                            if !transcript.translationTracks.isEmpty {
                                ForEach(transcript.translationTracks) { track in
                                Button(L10n.format("Translation · %@", track.displayLanguageLabel)) {
                                        store.selectTranslationLanguage(
                                            track.languageCode,
                                            forTranscription: transcript.id
                                        )
                                        store.useTranscript(
                                            transcript.id,
                                            forDub: job.id,
                                            track: .translation
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .disabled(store.transcriptions.allSatisfy { $0.result == nil })
                Spacer()
            }
        }
        .padding(AppTheme.Spacing.xl)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func segmentCard(
        job: WorkbenchDubJob,
        displayIndex: Int,
        segment: DubSegmentPayload
    ) -> some View {
        let usage = segmentUsage(segment.text, language: job.language)
        let seconds = estimateDurationSeconds(segment.text, language: job.language)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Text("\(displayIndex + 1)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .frame(minWidth: AppTheme.zoomed(22), minHeight: AppTheme.zoomed(22))
                    .background(AppTheme.Background.raisedColor, in: Capsule())


                VoiceReferencePicker(
                    selection: segmentVoiceBinding(job.id, segmentIndex: segment.index),
                    languageCode: job.language,
                    defaultLabel: "Use default voice"
                )
                .frame(maxWidth: AppTheme.zoomed(260))

                Spacer(minLength: 0)

                Button {
                    rewriteSegmentIndex = segment.index
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Edit script with AI"))
                .disabled(segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    store.deleteDubSegment(job.id, segmentIndex: segment.index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled((job.segments?.count ?? 0) <= 1)
                .help(L10n.string("Delete segment"))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(AppTheme.Background.raisedColor.opacity(0.55))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                DubScriptEditor(
                    text: segmentTextBinding(job.id, segmentIndex: segment.index)
                )

                HStack {
                    Text(L10n.format("%@ %@", usage.count, L10n.string(key: usage.unit)))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                    Text(L10n.format("Estimated ~%@s", seconds))
                        .foregroundStyle(
                            seconds > 108
                                ? AppTheme.Status.warningColor
                                : AppTheme.Text.mutedColor
                        )
                }
                .font(.system(size: AppTheme.FontSize.xs))
            }
            .padding(AppTheme.Spacing.md)
        }
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func addSegmentButton(_ jobID: UUID) -> some View {
        Button {
            store.addDubSegment(jobID)
        } label: {
            Label("Add a dub segment", systemImage: "plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.lg)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    private func generateBar(job: WorkbenchDubJob, segmentCount: Int, totalSeconds: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("%@ Segments · ~%@ s", segmentCount, totalSeconds))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(L10n.string(key: readyLabel(job)))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
            }
            Spacer(minLength: 0)
            if job.state.isActive {
                Button(role: .cancel) {
                    store.cancelDub(job.id)
                } label: {
                    Label(L10n.string("Cancel"), systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .disabled(job.state == .cancelling)
            } else {
                Button {
                    start(job)
                } label: {
                    Label(
                        L10n.string(job.state == .completed ? "Regenerate" : "Generate"),
                        systemImage: job.state == .completed ? "arrow.clockwise" : "sparkles"
                    )
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Accent.primary)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canGenerate(job))
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: AppTheme.zoomed(720))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func progressCard(_ job: WorkbenchDubJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string(key: progressPhase(job)).uppercased())
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Text(L10n.display(progressDisplayMessage(job)))
                Spacer()
                if let current = job.progressCompleted, let total = job.progressTotal {
                    Text("\(current)/\(total)").monospacedDigit()
                }
                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .font(.system(size: AppTheme.FontSize.sm))
            ProgressView(value: job.progress)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    private func outputCard(output: URL) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "waveform")
                    .font(.system(size: AppTheme.IconSize.lg))
                    .foregroundStyle(AppTheme.Accent.primary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(output.lastPathComponent)
                    Text(output.path)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            DubOutputPlayer(
                url: output,
                onPlaybackStart: { VoiceLibraryStore.shared.stopPlayback() }
            )
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func fieldColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(height: AppTheme.zoomed(16), alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start(_ job: WorkbenchDubJob) {
        guard canGenerate(job) else { return }
        showProcessingOptions = true
    }

    private func continueGeneration(jobID: UUID, placement: TaskPlacement) {
        guard store.dubs.contains(where: { $0.id == jobID }) else { return }
        store.updateDub(jobID) { $0.placement = placement }
        store.normalizeDubSegments(jobID)
        showProcessingOptions = false
        store.runDub(jobID)
    }

    private func canGenerate(_ job: WorkbenchDubJob) -> Bool {
        let texts = (job.segments ?? []).map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return texts.contains { !$0.isEmpty }
    }

    private func readyLabel(_ job: WorkbenchDubJob) -> String {
        if job.state == .running { return L10n.key("Generating…") }
        if job.state == .cancelling { return L10n.key("Cancelling…") }
        if job.state == .completed { return L10n.key("Ready to regenerate") }
        return L10n.key("Ready to generate")
    }

    private func progressDisplayMessage(_ job: WorkbenchDubJob) -> String {
        if let current = job.progressCompleted,
           let total = job.progressTotal,
           total > 0,
           job.progressStep?.localizedCaseInsensitiveContains("script") == true {
            return L10n.format("Synthesizing %@/%@", current, total)
        }
        return job.progressMessage
    }

    private func progressPhase(_ job: WorkbenchDubJob) -> String {
        let step = job.progressStep?.lowercased() ?? ""
        if step.contains("script") || step.contains("synth") { return L10n.key("Synthesizing") }
        if step.contains("align") { return L10n.key("Aligning audio") }
        if step.contains("upload") || step.contains("download") || step.contains("sync") {
            return L10n.key("Saving result")
        }
        if step.contains("final") || step.contains("cleanup") { return L10n.key("Finalizing") }
        if step.contains("cancel") { return L10n.key("Cancelled") }
        if step.contains("fail") { return L10n.key("Failed") }
        if step.contains("queue") { return L10n.key("Queued") }
        if step.contains("prepar") || step.contains("create") { return L10n.key("Preparing") }
        return job.flowProgressStage?.title ?? L10n.key("Preparing")
    }

    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                let raw = store.dubs.first { $0.id == id }?.title ?? ""
                return SessionTitlePolicy.isUserProvided(raw) ? raw : ""
            },
            set: { value in
                store.updateDub(id) {
                    $0.title = SessionTitlePolicy.normalizedUserTitle(value) ?? ""
                }
            }
        )
    }

    private func referenceVoiceBinding(_ id: UUID) -> Binding<UUID?> {
        Binding(
            get: { store.dubs.first { $0.id == id }?.referenceVoiceID },
            set: { value in store.updateDub(id) { $0.referenceVoiceID = value } }
        )
    }

    private func segmentVoiceBinding(_ id: UUID, segmentIndex: Int) -> Binding<UUID?> {
        Binding(
            get: { store.dubs.first { $0.id == id }?.resolvedSegmentVoiceIDs[segmentIndex] },
            set: { value in
                store.updateDub(id) { job in
                    var assignments = job.resolvedSegmentVoiceIDs
                    assignments[segmentIndex] = value
                    job.segmentVoiceIDs = assignments.isEmpty ? nil : assignments
                }
            }
        )
    }

    private func segmentTextBinding(_ id: UUID, segmentIndex: Int) -> Binding<String> {
        Binding(
            get: {
                store.dubs.first { $0.id == id }?
                    .segments?.first { $0.index == segmentIndex }?.text ?? ""
            },
            set: { value in store.updateDubSegmentText(id, segmentIndex: segmentIndex, text: value) }
        )
    }

    private func languageBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                let code = store.dubs.first { $0.id == id }?.language ?? "en"
                return code == "auto" ? "en" : code
            },
            set: { value in store.updateDub(id) { $0.language = value } }
        )
    }

    private func segmentUsage(_ text: String, language: String) -> (count: Int, unit: String) {
        let primary = language.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        if ["zh", "ja", "ko", "yue"].contains(primary) {
            return (text.count, text.count == 1 ? "character" : "characters")
        }
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
        return (words, words == 1 ? "word" : "words")
    }

    private func estimateDurationSeconds(_ text: String, language: String) -> Int {
        let compact = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !compact.isEmpty else { return 0 }
        let primary = language.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        let rate: Double = switch primary {
        case "zh", "yue": 6.3
        case "ja": 7.1
        case "ko": 6.5
        case "de": 13.0
        case "fr": 13.4
        case "ru": 12.5
        case "pt": 13.5
        case "es": 14.4
        case "it": 14.0
        default: 14.5
        }
        return Int(ceil(Double(compact.count) / rate))
    }
}

private struct DubRewriteTarget: Identifiable {
    let segmentIndex: Int
    var id: Int { segmentIndex }
}

private struct DubRewriteSheet: View {
    let jobID: UUID
    let segmentIndex: Int
    let onDismiss: () -> Void

    @Bindable private var store = WorkbenchStore.shared
    @State private var draft = ""
    @State private var rewrite = DubRewriteController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("AI edit"))
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Describe how AI should revise this segment."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Button {
                    rewrite.cancel()
                    dismiss()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            Text(L10n.string("Editing instructions"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            DubScriptEditor(text: $draft, placeholder: L10n.string("Make it shorter, more conversational, or change the tone…"))
                .disabled(rewrite.isRunning)
            if let error = rewrite.errorMessage {
                Text(L10n.display(error)).foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    rewrite.cancel()
                    dismiss()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.string(rewrite.isRunning ? "Rewriting…" : "Apply AI edit")) {
                    rewrite.start(store: store, jobID: jobID, segmentIndex: segmentIndex, instruction: draft) {
                        dismiss()
                        onDismiss()
                    }
                }
                .disabled(rewrite.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.Workbench.dubSheetWidth)
        .onDisappear { rewrite.cancel() }
    }
}

struct DubScriptEditor: View {
    @Binding var text: String
    var placeholder: String = "Enter dub script here..."
    var minHeight: CGFloat = AppTheme.Workbench.dubScriptMinHeight

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            NativePlaceholderTextEditor(text: $text, placeholder: placeholder)
                .frame(minHeight: minHeight)
            HStack {
                Spacer()
                InlineVoiceInputControl(text: $text)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }
}
