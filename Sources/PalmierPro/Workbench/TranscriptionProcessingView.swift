import SwiftUI

struct TranscriptionProcessingView: View {
    let jobID: UUID

    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared
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
                    ContentUnavailableView(L10n.string("Processing job unavailable"), systemImage: "waveform")
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
                appendEvent(L10n.string("Transcription completed"))
            } else if state == .failed {
                appendEvent(job?.errorMessage.map(L10n.display) ?? L10n.string("Processing failed"))
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
                    Text(L10n.format("File %@ of %@", batchPosition.current, batchPosition.total))
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
                    Text(L10n.string(job.state == .failed ? "Needs attention" : "Processing"))
                        .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    Text(etaText(for: job))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(metaLine(for: job))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                Spacer()
                Button(L10n.string("Cancel")) {
                    store.cancelActiveTranscriptionBatch()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .disabled(job.state == .cancelling || job.state == .completed)
            }

            if let error = job.errorMessage, job.state == .failed {
                Label(L10n.display(error), systemImage: "exclamationmark.triangle.fill")
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

            Text(L10n.display(job.progressMessage))
                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            if isPreparingLocalModels(job) {
                localModelDownloadPanel(for: job)
            }

            milestoneList(for: job)

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

    private func isPreparingLocalModels(_ job: WorkbenchTranscriptionJob) -> Bool {
        job.compute == .local && job.progressStep == "preparing_models"
    }

    private func localModelPlan(for job: WorkbenchTranscriptionJob) -> LocalModelInstallPlan {
        models.installPlan(languageCode: job.languageCode, speakerCount: job.speakerCount.count)
    }

    private func localModelDownloadPanel(for job: WorkbenchTranscriptionJob) -> some View {
        let plan = localModelPlan(for: job)
        let status = models.preparationStatus(for: plan.items.map(\.id))
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.string("Preparing speech features"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Spacer()
                Text("\(Int((status.progress * 100).rounded()))%")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Text(L10n.string("Speech processing runs on this Mac. This first-time setup can take several minutes; the resources are reused for future files."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: min(max(status.progress, 0), 1))
                .tint(.indigo)
            Text(L10n.display(status.userFacingMessage))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(plan.items) { item in
                    localModelRow(item, state: models.state(for: item.id))
                }
            }
            Text(L10n.format(
                "Downloaded %@ of %@",
                LocalModelInstallPlan.formatBytes(status.completedBytes),
                LocalModelInstallPlan.formatBytes(status.totalBytes)
            ))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(Color.indigo.opacity(0.24), lineWidth: 1)
        }
    }

    private func localModelRow(
        _ item: LocalModelInstallPlan.Item,
        state: LocalModelDownloadState
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: modelStateIcon(state))
                .foregroundStyle(modelStateColor(state))
                .frame(width: 16)
            Text(L10n.display(item.userFacingTitle))
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(L10n.string(modelStateLabel(state)))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private func modelStateIcon(_ state: LocalModelDownloadState) -> String {
        switch state {
        case .installed: "checkmark.circle.fill"
        case .queued, .downloading, .verifying: "arrow.down.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .notInstalled: "circle"
        }
    }

    private func modelStateColor(_ state: LocalModelDownloadState) -> Color {
        switch state {
        case .installed: AppTheme.Status.successColor
        case .queued, .downloading, .verifying: AppTheme.Accent.primary
        case .failed: AppTheme.Status.errorColor
        case .notInstalled: AppTheme.Text.mutedColor
        }
    }

    private func modelStateLabel(_ state: LocalModelDownloadState) -> String {
        switch state {
        case .installed: "Ready"
        case .queued: "Waiting"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .failed: "Needs retry"
        case .notInstalled: "Not downloaded"
        }
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
                        .font(.system(size: AppTheme.FontSize.xs, weight: .bold))
                        .foregroundStyle(.white)
                } else if state == .active {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(key: milestone.title))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: state == .active ? .semibold : .medium))
                    .foregroundStyle(state == .pending ? AppTheme.Text.mutedColor : AppTheme.Text.primaryColor)
                if let detail {
                    Text(L10n.display(detail))
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
                }

                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    ForEach(events) { event in
                        Text(verbatim: "\(event.time)  \(L10n.display(event.message))")
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        } label: {
            HStack {
                Text(L10n.string("Advanced Details"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Spacer()
                Text(L10n.format("%@ events", events.count))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private func cloudPipelineDetails(for job: WorkbenchTranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string("Cloud pipeline"))
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(L10n.string("Speech recognition and result assembly run in VoxStudio Cloud. This Mac does not need additional downloads for this task."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ProcessingMilestone.allCases) { milestone in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string(key: milestone.title))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    ForEach(cloudPipelineLines(for: milestone, job: job), id: \.self) { line in
                        Text(L10n.display(line))
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
            return [L10n.string("Cloud session setup and secure media transfer")]
        case .preprocessing:
            return [L10n.string("Audio preparation managed by VoxStudio Cloud")]
        case .speechRecognition:
            if let current = job.progressCompleted, let total = job.progressTotal, total > 0 {
                return [L10n.format("Cloud speech recognition · %@ of %@ segments", current, total)]
            }
            return [L10n.string("Cloud speech recognition")]
        case .finalizing:
            return [L10n.string(job.normalizedTargetLanguageCode == nil
                ? "Transcript and subtitle assembly in VoxStudio Cloud"
                : "Transcript, subtitle, and translation assembly in VoxStudio Cloud")]
        case .completed:
            return [L10n.string("Result committed to the session")]
        }
    }

    private func etaText(for job: WorkbenchTranscriptionJob) -> String {
        if job.state == .failed { return L10n.string("Processing stopped") }
        if job.state == .cancelling { return L10n.string("Cancelling…") }
        if job.state == .completed { return L10n.string("Completed") }
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .queued {
            return L10n.string("Estimated: waiting for local speech processing")
        }
        if isPreparingLocalModels(job) {
            return L10n.string("Preparing speech features — first-time setup may take several minutes")
        }
        if job.flowProgressStage == .transcription,
           job.progressStep == LocalSpeechStage.detectingSpeech.rawValue,
           let completed = job.progressCompleted,
           let total = job.progressTotal,
           total > 0 {
            return completed >= total ? L10n.string("Speech check complete") : L10n.display(job.progressMessage)
        }
        if job.progress < 0.08 {
            return L10n.string("Estimated: about <1 min left")
        }
        if job.progress < 0.55 {
            return L10n.string("Estimated: a few minutes left")
        }
        return L10n.string("Estimated: wrapping up")
    }

    private func metaLine(for job: WorkbenchTranscriptionJob) -> String {
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .queued {
            return L10n.string("Queued • Local serial processing")
        }
        if job.compute == .cloud,
           job.isActivelyProcessing,
           let completed = job.progressCompleted,
           let total = job.progressTotal,
           total > 0 {
            let boundedCompleted = min(max(completed, 0), total)
            return L10n.format("Transcribing: %@/%@ • VoxStudio Cloud", boundedCompleted, total)
        }
        if isPreparingLocalModels(job) {
            return L10n.string("Preparing speech features • This Mac")
        }
        if job.isActivelyProcessing {
            let location = L10n.string(job.compute == .cloud ? "VoxStudio Cloud" : "This Mac")
            if let completed = job.progressCompleted,
               let total = job.progressTotal,
               total > 0 {
                let boundedCompleted = min(max(completed, 0), total)
                return L10n.format("Processing: %@/%@ • %@", boundedCompleted, total, location)
            }
            return L10n.format("Processing • %@", location)
        }
        return L10n.display(job.state.label)
    }

    private func activeMilestone(for job: WorkbenchTranscriptionJob) -> ProcessingMilestone {
        if job.state == .completed { return .completed }
        if job.compute == .local,
           store.isTranscriptionQueued(jobID),
           job.state == .queued { return .preparing }
        switch job.flowProgressStage {
        case .subtitlePreparation, .translation: return .finalizing
        case .transcription, .none:
            break
        default:
            break
        }
        let step = (job.progressStep ?? "").lowercased()
        if step == "preparing_models" {
            return .preparing
        }
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
            if isPreparingLocalModels(job) {
                return L10n.string("Preparing and verifying the speech resources listed above. They stay on this Mac for future files.")
            }
            return job.compute == .cloud
                ? L10n.string("Preparing your session in VoxStudio Cloud.")
                : L10n.string("Your file is queued. Only one local transcription runs at a time to protect GPU memory.")
        case .preprocessing:
            return job.compute == .cloud
                ? L10n.string("VoxStudio Cloud is preparing the media.")
                : L10n.string("We’re cleaning and optimizing the audio so speech can be recognized more accurately.")
        case .speechRecognition:
            return L10n.display(job.progressMessage)
        case .finalizing:
            return job.compute == .cloud
                ? L10n.string("VoxStudio Cloud is assembling the transcript and optional translation.")
                : L10n.string("Polishing timings, speakers, and optional translation.")
        case .completed:
            return L10n.string("Opening your session…")
        }
    }

    private func seedEvents() {
        guard events.isEmpty else { return }
        appendEvent(L10n.string(job?.compute == .cloud ? "Cloud processing started" : "Local processing started"))
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
