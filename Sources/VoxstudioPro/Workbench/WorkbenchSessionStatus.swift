import SwiftUI

struct SessionProcessingSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transcription
        case translation
        case dubbing

        var defaultStageTitle: String {
            switch self {
            case .transcription: L10n.key("Transcription")
            case .translation: L10n.key("Translation")
            case .dubbing: L10n.key("Dubbing")
            }
        }

        var systemImage: String {
            switch self {
            case .transcription: "waveform"
            case .translation: "character.book.closed.fill"
            case .dubbing: "waveform.and.mic"
            }
        }

        var countUnit: String {
            switch self {
            case .translation: L10n.key("batches")
            case .transcription, .dubbing: L10n.key("steps")
            }
        }
    }

    let kind: Kind
    let fraction: Double
    let message: String
    let stageTitle: String?
    let completed: Int?
    let total: Int?
    let targetLanguageCode: String?
    let compute: TaskComputeDestination

    init(
        kind: Kind,
        fraction: Double,
        message: String,
        stageTitle: String?,
        completed: Int?,
        total: Int?,
        targetLanguageCode: String?,
        compute: TaskComputeDestination
    ) {
        self.kind = kind
        self.fraction = Self.normalizedFraction(fraction)
        self.message = Self.normalizedMessage(message, fallback: L10n.key("Processing media…"))
        self.stageTitle = stageTitle
        self.completed = completed
        self.total = total
        self.targetLanguageCode = targetLanguageCode
        self.compute = compute
    }

    init(job: WorkbenchTranscriptionJob) {
        self.kind = job.normalizedTargetLanguageCode == nil ? .transcription : .translation
        self.fraction = Self.normalizedFraction(job.progress)
        self.message = Self.normalizedMessage(job.progressMessage, fallback: L10n.key("Processing media…"))
        self.stageTitle = job.flowProgressStage?.title ?? job.progressStage?.title
        self.completed = job.progressCompleted
        self.total = job.progressTotal
        self.targetLanguageCode = job.normalizedTargetLanguageCode
        self.compute = job.compute
    }

    init(job: WorkbenchDubJob) {
        self.kind = .dubbing
        self.fraction = Self.normalizedFraction(job.progress)
        self.message = Self.normalizedMessage(job.progressMessage, fallback: L10n.key("Generating dub…"))
        self.stageTitle = job.flowProgressStage?.title
        self.completed = job.progressCompleted
        self.total = job.progressTotal
        self.targetLanguageCode = nil
        self.compute = job.resolvedCompute
    }

    var resolvedStageTitle: String {
        if let stageTitle,
           !stageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stageTitle
        }
        return kind.defaultStageTitle
    }

    var progressDetail: String? {
        var details: [String] = []
        if let completed, let total, total > 0 {
            let boundedCompleted = min(max(completed, 0), total)
            details.append("\(boundedCompleted) of \(total) \(kind.countUnit)")
        }
        if let targetLanguageCode {
            let compactCode = WorkbenchLanguageLabel.compact(targetLanguageCode)
            if compactCode != "—" {
                details.append("Target \(compactCode)")
            }
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    var locationLabel: String {
        compute == .cloud ? TaskPlacementCopy.voxStudioCloud : TaskPlacementCopy.thisMac
    }

    var locationSystemImage: String {
        compute == .cloud ? "cloud" : "laptopcomputer"
    }

    private static func normalizedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func normalizedMessage(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Keeps each operation's diagnostics separate, even when the session has a usable older result.
struct SessionTaskDetail: Equatable, Sendable {
    let title: String
    let state: WorkbenchJobState
    let errorMessage: String?
    let nextStep: String

    init(title: String, state: WorkbenchJobState, errorMessage: String?, nextStep: String) {
        self.title = title
        self.state = state
        self.errorMessage = errorMessage
        self.nextStep = nextStep
    }

    init(job: WorkbenchTranscriptionJob) {
        let stage = job.flowProgressStage
        self.init(
            title: stage == .flow ? "Transcription" : stage?.title ?? "Transcription",
            state: job.state == .completed && job.result == nil ? .unknown : job.state,
            errorMessage: job.errorMessage,
            nextStep: "Open Transcribe, review the source and processing settings, then try again."
        )
    }

    init(job: WorkbenchDubJob) {
        let stage = job.flowProgressStage
        self.init(
            title: stage == .flow ? "Voiceover" : stage?.title ?? "Voiceover",
            state: job.state == .completed && job.outputURL == nil ? .unknown : job.state,
            errorMessage: job.errorMessage,
            nextStep: "Open Voiceover, review the voice and model settings, then generate again."
        )
    }

    var diagnostic: String? {
        guard state.needsAttention else { return nil }
        if let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        switch state {
        case .interrupted: return "This task stopped before it finished."
        case .unknown: return "The task status could not be verified."
        default: return "This task failed, but no error details were saved."
        }
    }

    var statusLabel: String { state == .failed ? "Failed" : state.label }

    var systemImage: String {
        if state.needsAttention { return "exclamationmark.triangle.fill" }
        if state == .completed { return "checkmark.circle.fill" }
        if state == .queued { return "clock" }
        if state.isActive { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if state == .cancelled { return "xmark.circle" }
        return "circle"
    }
}

struct SessionStatusBadge: View {
    /// Refresh-style glyph for active work; it spins while the task is running.
    private static let activitySymbol = "arrow.trianglehead.2.clockwise.rotate.90"

    let status: WorkbenchSessionStatus
    let processing: SessionProcessingSnapshot?
    let iconOnlyAttention: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        status: WorkbenchSessionStatus,
        processing: SessionProcessingSnapshot? = nil,
        iconOnlyAttention: Bool = false
    ) {
        self.status = status
        self.processing = processing
        self.iconOnlyAttention = iconOnlyAttention
    }

    var body: some View {
        if let processing, status.showsProcessing {
            activeStatus(processing)
        } else {
            compactStatus
        }
    }

    private func activeStatus(_ processing: SessionProcessingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                activityIcon(processing)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(activeTitle(for: processing).uppercased())
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Text(L10n.display(processing.message))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: AppTheme.Spacing.xs)

                Text(processing.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .contentTransition(.numericText())
            }

            progressBar(processing)

            HStack(spacing: AppTheme.Spacing.xs) {
                Text(L10n.display(processing.progressDetail ?? "Preparing next step…"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AppTheme.Spacing.xs)
                Label(L10n.string(key: processing.locationLabel), systemImage: processing.locationSystemImage)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(width: AppTheme.Workbench.sessionStatusWidth, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    color.opacity(AppTheme.Opacity.faint),
                    AppTheme.Background.raisedColor,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(color.opacity(AppTheme.Opacity.moderate), lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.sm)
        .help(L10n.display(processing.message))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activeTitle(for: processing))
        .accessibilityValue(accessibilityValue(for: processing))
    }

    private var compactStatus: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            statusLabel(
                status.primaryLabel,
                systemImage: systemImage,
                color: color,
                attention: !status.hasUsableResult && status.needsAttention,
                spins: systemImage == Self.activitySymbol
            )
            if let secondaryLabel = status.secondaryLabel {
                statusLabel(
                    secondaryLabel,
                    systemImage: secondarySystemImage,
                    color: secondaryColor,
                    attention: status.needsAttention,
                    spins: secondarySystemImage == Self.activitySymbol
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(status.tasks.filter { $0.state.needsAttention }.map {
            [L10n.string(key: $0.title), $0.diagnostic.map { L10n.display($0) } ?? ""]
                .joined(separator: ": ")
        }.joined(separator: ", "))
        .accessibilityLabel(
            [status.primaryLabel, status.secondaryLabel]
                .compactMap { $0 }
                .map { L10n.string(key: $0) }
                .joined(separator: ", ")
        )
    }

    private func statusLabel(
        _ title: String, systemImage: String, color: Color, attention: Bool = false, spins: Bool = false
    ) -> some View {
        let issues = status.tasks.filter { $0.state.needsAttention }
        let issueTitle = issues.first.map { L10n.format("%@ · %@", L10n.string(key: $0.title), L10n.string(key: $0.statusLabel)) }
        let label = attention ? (issueTitle ?? L10n.string(key: title)) : L10n.string(key: title)
        let help = issues.map {
            [L10n.string(key: $0.title), $0.diagnostic.map { L10n.display($0) } ?? "", L10n.string(key: $0.nextStep)]
                .filter { !$0.isEmpty }.joined(separator: ": ")
        }.joined(separator: "\n\n")
        return Label(label, systemImage: systemImage)
            .labelStyle(AttentionLabelStyle(iconOnly: attention && iconOnlyAttention, spinsIcon: spins))
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(color)
            .padding(.horizontal, attention && iconOnlyAttention ? AppTheme.Spacing.sm : AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(color.opacity(AppTheme.Opacity.soft), in: Capsule())
            .help(attention && !help.isEmpty ? help : label)
    }

    private func activeTitle(for processing: SessionProcessingSnapshot) -> String {
        let activity = status.displayTaskState == .cancelling
            ? L10n.string("Cancelling")
            : L10n.string(key: processing.resolvedStageTitle)
        return status.hasUsableResult ? L10n.format("Ready · %@", activity) : activity
    }

    private func activityIcon(_ processing: SessionProcessingSnapshot) -> some View {
        Group {
            if reduceMotion {
                activityIcon(processing, isPulsing: false)
            } else {
                PhaseAnimator([false, true]) { isPulsing in
                    activityIcon(processing, isPulsing: isPulsing)
                } animation: { _ in
                    .easeInOut(duration: AppTheme.Anim.pulse)
                }
            }
        }
    }

    private func activityIcon(
        _ processing: SessionProcessingSnapshot,
        isPulsing: Bool
    ) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(isPulsing ? AppTheme.Opacity.moderate : AppTheme.Opacity.soft))
            Image(systemName: processing.kind.systemImage)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(color)
        }
        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
        .scaleEffect(isPulsing ? AppTheme.Workbench.sessionStatusPulseScale : 1)
    }

    private func progressBar(_ processing: SessionProcessingSnapshot) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width * processing.fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(AppTheme.Opacity.muted))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, AppTheme.Accent.link],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
                    .overlay(alignment: .trailing) {
                        if width > 0 {
                            Circle()
                                .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.prominent))
                                .frame(width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm)
                                .blur(radius: AppTheme.Spacing.xxs)
                        }
                    }
            }
        }
        .frame(height: AppTheme.Workbench.sessionStatusProgressHeight)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.transition),
            value: processing.fraction
        )
        .accessibilityHidden(true)
    }

    private func accessibilityValue(for processing: SessionProcessingSnapshot) -> String {
        var values = [
            L10n.display(processing.message),
            processing.fraction.formatted(.percent.precision(.fractionLength(0))),
        ]
        if let detail = processing.progressDetail {
            values.append(L10n.display(detail))
        }
        return values.joined(separator: ", ")
    }

    private var color: Color {
        if status.hasUsableResult { return AppTheme.Status.successColor }
        return switch status.displayTaskState {
        case .completed: AppTheme.Status.successColor
        case .failed, .interrupted, .unknown: AppTheme.Status.errorColor
        case .queued, .running, .cancelling: AppTheme.Status.warningColor
        case .notStarted, .cancelled: AppTheme.Text.tertiaryColor
        }
    }

    private var systemImage: String {
        if status.hasUsableResult { return "checkmark.circle.fill" }
        return switch status.displayTaskState {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted, .unknown: "exclamationmark.triangle.fill"
        case .running, .cancelling: Self.activitySymbol
        case .queued: "clock"
        case .notStarted: "circle"
        case .cancelled: "xmark.circle"
        }
    }

    private var secondaryColor: Color {
        status.needsAttention ? AppTheme.Status.errorColor : AppTheme.Status.warningColor
    }

    private var secondarySystemImage: String {
        if status.needsAttention { return "exclamationmark.triangle.fill" }
        if status.hasAdditionalActivity { return Self.activitySymbol }
        if status.displayTaskState == .cancelled { return "xmark.circle" }
        if status.displayTaskState == .queued { return "clock" }
        return Self.activitySymbol
    }
}

private struct AttentionLabelStyle: LabelStyle {
    let iconOnly: Bool
    var spinsIcon = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            configuration.icon
                .modifier(SpinningIconModifier(active: spinsIcon))
            if !iconOnly { configuration.title }
        }
    }
}

/// Rotates an icon continuously while `active`, and holds it still under Reduce Motion.
private struct SpinningIconModifier: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(
            .rotate.wholeSymbol,
            options: .repeating,
            isActive: active && !reduceMotion
        )
    }
}

struct SessionStatusInfoButton: View {
    let status: WorkbenchSessionStatus?

    @State private var isPresented = false

    init(status: WorkbenchSessionStatus? = nil) {
        self.status = status
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("About session status"))
        .accessibilityLabel(L10n.string("About session status"))
        .accessibilityHint(L10n.string("Shows task details, error reasons, and next steps."))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SessionStatusHelp(status: status)
        }
    }
}

private struct SessionStatusHelp: View {
    let status: WorkbenchSessionStatus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Label(L10n.string("Session status"), systemImage: "info.circle.fill")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))

                if let status {
                    Label(L10n.string(status.hasUsableResult ? "Ready" : "No result yet"),
                          systemImage: status.hasUsableResult ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(status.hasUsableResult ? AppTheme.Status.successColor : AppTheme.Text.tertiaryColor)
                    if status.hasUsableResult {
                        Text(L10n.string("Your saved result is available to view, edit, and export."))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    ForEach(Array(status.tasks.enumerated()), id: \.offset) { _, task in
                        Divider()
                        taskDetail(task)
                    }
                } else {
                    Text(L10n.string("Ready means the latest committed result is available to view, edit, or export."))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppTheme.Spacing.xl)
        }
        .frame(width: AppTheme.Workbench.sessionStatusHelpWidth)
        .frame(maxHeight: AppTheme.zoomed(520))
        .background(AppTheme.Background.raisedColor)
    }

    private func taskDetail(_ task: SessionTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: task.systemImage)
                    .foregroundStyle(task.state.needsAttention ? AppTheme.Status.errorColor : AppTheme.Text.tertiaryColor)
                Text(L10n.string(key: task.title)).fontWeight(.semibold)
                Spacer()
                Text(L10n.string(key: task.statusLabel))
                    .foregroundStyle(task.state.needsAttention ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor)
            }
            if let diagnostic = task.diagnostic {
                Text(L10n.display(diagnostic))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .textSelection(.enabled)
                Text(L10n.string(key: task.nextStep))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Session status") {
    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
        SessionStatusBadge(
            status: WorkbenchSessionStatus(
                hasUsableResult: true,
                taskState: .running,
                hasAdditionalFailure: false
            ),
            processing: SessionProcessingSnapshot(
                kind: .translation,
                fraction: 0.62,
                message: "Translating subtitle windows…",
                stageTitle: "Translation",
                completed: 8,
                total: 13,
                targetLanguageCode: "zh",
                compute: .cloud
            )
        )
        SessionStatusBadge(status: WorkbenchSessionStatus(
            hasUsableResult: true,
            taskState: .completed,
            hasAdditionalFailure: false
        ))
    }
    .padding(AppTheme.Spacing.xl)
    .background(AppTheme.Background.baseColor)
}
