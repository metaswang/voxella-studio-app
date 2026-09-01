import SwiftUI

struct SessionProcessingSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transcription
        case translation
        case dubbing

        var defaultStageTitle: String {
            switch self {
            case .transcription: "Transcription"
            case .translation: "Translation"
            case .dubbing: "Dubbing"
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
            case .translation: "batches"
            case .transcription, .dubbing: "steps"
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
        self.message = Self.normalizedMessage(message, fallback: "Processing media…")
        self.stageTitle = stageTitle
        self.completed = completed
        self.total = total
        self.targetLanguageCode = targetLanguageCode
        self.compute = compute
    }

    init(job: WorkbenchTranscriptionJob) {
        self.kind = job.normalizedTargetLanguageCode == nil ? .transcription : .translation
        self.fraction = Self.normalizedFraction(job.progress)
        self.message = Self.normalizedMessage(job.progressMessage, fallback: "Processing media…")
        self.stageTitle = job.flowProgressStage?.title ?? job.progressStage?.title
        self.completed = job.progressCompleted
        self.total = job.progressTotal
        self.targetLanguageCode = job.normalizedTargetLanguageCode
        self.compute = job.compute
    }

    init(job: WorkbenchDubJob) {
        self.kind = .dubbing
        self.fraction = Self.normalizedFraction(job.progress)
        self.message = Self.normalizedMessage(job.progressMessage, fallback: "Generating dub…")
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

struct SessionStatusBadge: View {
    let state: WorkbenchJobState
    let processing: SessionProcessingSnapshot?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        state: WorkbenchJobState,
        processing: SessionProcessingSnapshot? = nil
    ) {
        self.state = state
        self.processing = processing
    }

    var body: some View {
        if let processing, state == .running || state == .cancelling {
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
                    Text((state == .cancelling ? "Cancelling" : processing.resolvedStageTitle).uppercased())
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Text(processing.message)
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
                Text(processing.progressDetail ?? "Preparing next step…")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AppTheme.Spacing.xs)
                Label(processing.locationLabel, systemImage: processing.locationSystemImage)
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
        .help(processing.message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state == .cancelling ? "Cancelling" : processing.resolvedStageTitle)
        .accessibilityValue(accessibilityValue(for: processing))
    }

    private var compactStatus: some View {
        Label(state.label, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(color)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(color.opacity(AppTheme.Opacity.soft), in: Capsule())
            .accessibilityLabel(state.label)
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
            processing.message,
            processing.fraction.formatted(.percent.precision(.fractionLength(0))),
        ]
        if let detail = processing.progressDetail {
            values.append(detail)
        }
        return values.joined(separator: ", ")
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

#Preview("Session status") {
    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
        SessionStatusBadge(
            state: .running,
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
        SessionStatusBadge(state: .completed)
    }
    .padding(AppTheme.Spacing.xl)
    .background(AppTheme.Background.baseColor)
}
