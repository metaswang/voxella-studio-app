import SwiftUI

struct TranscriptionProcessingView: View {
    let jobID: UUID

    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared
    @State private var events: [ProcessingLogEvent] = []
    @State private var showAdvanced = false
    @State private var wavePhase: CGFloat = 0

    private var job: WorkbenchTranscriptionJob? {
        store.transcriptions.first { $0.id == jobID }
    }

    private var batchPosition: (current: Int, total: Int)? {
        guard let batch = store.activeTranscriptionBatch, batch.jobIDs.count > 1,
              let index = batch.jobIDs.firstIndex(of: jobID) else { return nil }
        return (index + 1, batch.jobIDs.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if let job {
                    header(job)
                    processingCard(job)
                    advancedDetails(for: job)
                } else {
                    ContentUnavailableView("Processing job unavailable", systemImage: "waveform")
                }
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(AppTheme.Background.baseColor)
        .onAppear { seedEvents() }
        .onChange(of: job?.progressMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            appendEvent(message)
        }
        .onChange(of: job?.state) { _, state in
            if state == .completed {
                appendEvent("Transcription completed")
            } else if state == .failed {
                appendEvent(job?.errorMessage ?? "Processing failed")
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                wavePhase = 1
            }
        }
    }

    private func header(_ job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.sessionTitle)
                .font(.system(size: AppTheme.FontSize.title2, weight: .semibold))
            HStack(spacing: AppTheme.Spacing.md) {
                Label(job.sourceURL.lastPathComponent, systemImage: "doc")
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let batchPosition {
                    Text("File \(batchPosition.current) of \(batchPosition.total)")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.18), in: Capsule())
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private func processingCard(_ job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.state == .failed ? "Needs attention" : "Processing")
                        .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    Text(etaText(for: job))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(metaLine(for: job))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                Spacer()
                Button("Cancel") {
                    store.cancelActiveTranscriptionBatch()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .disabled(job.state == .cancelling || job.state == .completed)
            }

            if let error = job.errorMessage, job.state == .failed {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Status.errorColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            }

            waveBars

            ProgressView(value: max(0.02, job.progress))
                .tint(.indigo)
                .animation(.easeInOut(duration: 0.35), value: job.progress)

            Text(job.progressMessage)
                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            milestoneList(for: job)

            if job.compute == .local,
               !models.hasRequiredTranscriptionModels(
                   languageCode: job.languageCode,
                   speakerCount: job.speakerCount.count
               ) {
                HStack {
                    Text("Required speech models are missing.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                    Spacer()
                    Button("Manage Models") { models.presentManager() }
                        .buttonStyle(.bordered)
                }
            }

            if job.state == .failed || job.state == .cancelled {
                HStack {
                    Button("Back") {
                        store.dismissTranscriptionProcessing()
                    }
                    Spacer()
                    Button("Retry") {
                        store.runTranscription(job.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
        }
        .padding(AppTheme.Spacing.xl)
        .background(
            LinearGradient(
                colors: [
                    AppTheme.Background.surfaceColor,
                    AppTheme.Background.raisedColor.opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.indigo.opacity(0.35), Color.cyan.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.indigo.opacity(0.12), radius: 24, y: 10)
    }

    private var waveBars: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<18, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.cyan.opacity(0.7)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 7, height: barHeight(for: index))
                    .opacity(0.55 + Double((index % 4)) * 0.1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.vertical, 8)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [18, 34, 52, 40, 64, 28, 48, 36, 58, 22, 44, 62, 30, 50, 38, 56, 26, 42]
        let value = base[index % base.count]
        return value + (wavePhase * CGFloat((index % 3) * 6))
    }

    private func milestoneList(for job: WorkbenchTranscriptionJob) -> some View {
        let active = activeMilestone(for: job)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(ProcessingMilestone.allCases) { milestone in
                milestoneRow(
                    milestone,
                    state: milestoneState(milestone, active: active, job: job),
                    detail: milestoneDetail(milestone, job: job, active: active)
                )
            }
        }
    }

    private func milestoneRow(
        _ milestone: ProcessingMilestone,
        state: MilestoneVisualState,
        detail: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.fill)
                    .frame(width: 22, height: 22)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if state == .active {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(milestone.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: state == .active ? .semibold : .medium))
                    .foregroundStyle(state == .pending ? AppTheme.Text.mutedColor : AppTheme.Text.primaryColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func advancedDetails(for job: WorkbenchTranscriptionJob) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if job.compute == .cloud {
                    cloudPipelineDetails(for: job)
                } else {
                    stageModelList(for: job)
                }

                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    ForEach(events) { event in
                        Text("\(event.time)  \(event.message)")
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        } label: {
            HStack {
                Text("Advanced Details")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Spacer()
                Text("\(events.count) events")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private func cloudPipelineDetails(for job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Cloud pipeline")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Speech recognition and result assembly run in VoxStudio Cloud. This Mac does not need speech models for this task.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ProcessingMilestone.allCases) { milestone in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(milestone.title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    ForEach(cloudPipelineLines(for: milestone, job: job), id: \.self) { line in
                        Text(line)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func cloudPipelineLines(
        for milestone: ProcessingMilestone,
        job: WorkbenchTranscriptionJob
    ) -> [String] {
        switch milestone {
        case .preparing:
            return ["Cloud session setup and secure media transfer"]
        case .preprocessing:
            return ["Audio preparation managed by VoxStudio Cloud"]
        case .speechRecognition:
            if let current = job.progressCompleted, let total = job.progressTotal, total > 0 {
                return ["Cloud speech recognition · \(current) of \(total) segments"]
            }
            return ["Cloud speech recognition"]
        case .finalizing:
            return [job.normalizedTargetLanguageCode == nil
                ? "Transcript and subtitle assembly in VoxStudio Cloud"
                : "Transcript, subtitle, and translation assembly in VoxStudio Cloud"]
        case .completed:
            return ["Result committed to the session"]
        }
    }

    private func stageModelList(for job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Models by stage")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            ForEach(ProcessingMilestone.allCases) { milestone in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(milestone.title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    ForEach(modelLines(for: milestone, job: job), id: \.self) { line in
                        Text(line)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func modelLines(
        for milestone: ProcessingMilestone,
        job: WorkbenchTranscriptionJob
    ) -> [String] {
        switch milestone {
        case .preparing:
            return ["No model · local job admission and media preparation"]
        case .preprocessing:
            var lines = [localModelTitle(.sileroVAD)]
            if job.languageCode == nil {
                lines.append(localModelTitle(.spokenLanguageID))
            }
            return lines
        case .speechRecognition:
            var lines = [
                localModelTitle(.qwen3ASR17B8Bit),
                localModelTitle(.parakeetTDT06Bv3),
                localModelTitle(models.activeASRModelID),
            ]
            if job.languageCode == nil || ASREngineLanguagePolicy.engine(forLanguageCode: job.languageCode) != .parakeet {
                lines.append(localModelTitle(.forcedAligner))
            }
            if job.speakerCount.count == 1 {
                lines.append("Deterministic single-speaker assignment · no diarization model")
            } else {
                lines.append(localModelTitle(.sortformerDiarization))
            }
            return lines
        case .finalizing:
            let subtitleWillRun = job.shouldProcessSubtitles(
                hasAPIKey: llmSettings.hasConfiguredModel(for: .subtitleProcessing)
            ) || job.normalizedTargetLanguageCode != nil
            var lines = [
                subtitleWillRun
                    ? "Subtitle cleanup · configured route: \(llmRouteDescription(for: .subtitleProcessing))"
                    : "Subtitle cleanup · not run",
            ]
            if job.normalizedTargetLanguageCode != nil {
                lines.append("Translation · configured route: \(llmRouteDescription(for: .translation))")
            } else {
                lines.append("Translation · not run")
            }
            return lines
        case .completed:
            return ["No additional model · result committed to the session"]
        }
    }

    private func localModelTitle(_ id: LocalModelID) -> String {
        models.descriptor(for: id).title
    }

    private func llmRouteDescription(for useCase: LLMUseCase) -> String {
        let chain = llmSettings.route(for: useCase).modelChain
        return chain.isEmpty ? "not configured" : chain.joined(separator: " → ")
    }

    private func etaText(for job: WorkbenchTranscriptionJob) -> String {
        if job.state == .failed { return "Processing stopped" }
        if job.state == .cancelling { return "Cancelling…" }
        if job.state == .completed { return "Completed" }
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .ready {
            return "Estimated: waiting for the local ASR slot"
        }
        if job.progress < 0.08 {
            return "Estimated: about <1 min left"
        }
        if job.progress < 0.55 {
            return "Estimated: a few minutes left"
        }
        return "Estimated: wrapping up"
    }

    private func metaLine(for job: WorkbenchTranscriptionJob) -> String {
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .ready {
            return "Queued • Local serial processing"
        }
        if job.compute == .cloud,
           job.isActivelyProcessing,
           let completed = job.progressCompleted,
           let total = job.progressTotal,
           total > 0 {
            let boundedCompleted = min(max(completed, 0), total)
            return "Transcribing: \(boundedCompleted)/\(total) • VoxStudio Cloud"
        }
        if job.isActivelyProcessing {
            let location = job.compute == .cloud ? "VoxStudio Cloud" : TaskPlacementCopy.thisMac
            return "\(job.progressStep ?? "processing") • \(location)"
        }
        return job.state.label
    }

    private func activeMilestone(for job: WorkbenchTranscriptionJob) -> ProcessingMilestone {
        if job.state == .completed { return .completed }
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .ready { return .preparing }
        switch job.flowProgressStage {
        case .subtitlePreparation, .translation: return .finalizing
        case .transcription, .none:
            break
        default:
            break
        }
        let step = (job.progressStep ?? "").lowercased()
        if ["finalizing", "subtitle", "translate", "translation"].contains(where: { step.contains($0) }) {
            return .finalizing
        }
        if ["recognizing", "aligning", "diarizing", "assigning"].contains(where: { step.contains($0) }) {
            return .speechRecognition
        }
        if ["decoding", "detecting", "preprocess", "preparing", "flow_started"].contains(where: { step.contains($0) }) {
            return .preprocessing
        }
        return job.progress < 0.12 ? .preprocessing : .speechRecognition
    }

    private func milestoneState(
        _ milestone: ProcessingMilestone,
        active: ProcessingMilestone,
        job: WorkbenchTranscriptionJob
    ) -> MilestoneVisualState {
        if job.state == .completed { return .done }
        if milestone.rank < active.rank { return .done }
        if milestone == active { return .active }
        return .pending
    }

    private func milestoneDetail(
        _ milestone: ProcessingMilestone,
        job: WorkbenchTranscriptionJob,
        active: ProcessingMilestone
    ) -> String? {
        guard milestone == active else { return nil }
        switch milestone {
        case .preparing:
            return job.compute == .cloud
                ? "Preparing your session in VoxStudio Cloud."
                : "Your file is queued. Only one local transcription runs at a time to protect GPU memory."
        case .preprocessing:
            return job.compute == .cloud
                ? "VoxStudio Cloud is preparing the media."
                : "We’re cleaning and optimizing the audio so speech can be recognized more accurately."
        case .speechRecognition:
            return job.progressMessage
        case .finalizing:
            return job.compute == .cloud
                ? "VoxStudio Cloud is assembling the transcript and optional translation."
                : "Polishing timings, speakers, and optional translation."
        case .completed:
            return "Opening your session…"
        }
    }

    private func seedEvents() {
        guard events.isEmpty else { return }
        appendEvent(job?.compute == .cloud ? "Cloud processing started" : "Local processing started")
        if let message = job?.progressMessage {
            appendEvent(message)
        }
    }

    private func appendEvent(_ message: String) {
        if events.last?.message == message { return }
        events.append(ProcessingLogEvent(message: message))
    }
}

private struct ProcessingLogEvent: Identifiable {
    let id = UUID()
    let time: String
    let message: String

    init(message: String) {
        self.time = Date().formatted(date: .omitted, time: .standard)
        self.message = message
    }
}

private enum ProcessingMilestone: Int, CaseIterable, Identifiable {
    case preparing
    case preprocessing
    case speechRecognition
    case finalizing
    case completed

    var id: Int { rawValue }
    var rank: Int { rawValue }

    var title: String {
        switch self {
        case .preparing: "Preparing"
        case .preprocessing: "Preprocessing"
        case .speechRecognition: "Speech Recognition"
        case .finalizing: "Finalizing Results"
        case .completed: "Completed"
        }
    }
}

private enum MilestoneVisualState {
    case pending, active, done

    var fill: Color {
        switch self {
        case .pending: AppTheme.Background.raisedColor
        case .active: Color.indigo
        case .done: AppTheme.Status.successColor
        }
    }
}
