import SwiftUI

struct DubProcessingOptionsSheet: View {
    let job: WorkbenchDubJob
    let onPrepareCloud: ((TaskPlacement) async -> CloudAccessPreparation)?
    let onCancel: () -> Void
    let onContinue: (DubSubmission) -> Void

    @State private var storageDestination: TaskStorageDestination
    @State private var computeDestination: TaskComputeDestination
    @State private var estimate: CloudUsageEstimate?
    @State private var isLoadingEstimate = false
    @State private var isPreparingCloud = false
    @State private var cloudAccessError: String?
    @State private var estimateError = false
    @State private var estimateReloadID = UUID()
    @Bindable private var account = AccountService.shared

    init(
        job: WorkbenchDubJob,
        onPrepareCloud: ((TaskPlacement) async -> CloudAccessPreparation)? = nil,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (DubSubmission) -> Void
    ) {
        self.job = job
        self.onPrepareCloud = onPrepareCloud
        self.onCancel = onCancel
        self.onContinue = onContinue
        _storageDestination = State(initialValue: job.placement.storage)
        _computeDestination = State(initialValue: job.placement.compute)
    }

    private var placement: TaskPlacement {
        TaskPlacement(storage: storageDestination, compute: computeDestination)
    }

    private var cloudComputeSelected: Bool {
        computeDestination == .cloud
    }

    private var continueDisabled: Bool {
        guard cloudComputeSelected, account.isSignedIn else { return false }
        guard !isLoadingEstimate, !estimateError, let estimate else { return true }
        return !estimate.canAfford
    }

    private var notice: CloudCreditNotice {
        guard cloudComputeSelected else { return .none }
        return CloudCreditNoticePolicy.notice(
            isSignedIn: account.isSignedIn,
            isPaid: account.isPaid,
            estimate: estimate,
            estimateFailed: estimateError
        )
    }

    private var estimateTaskID: String {
        [
            job.id.uuidString,
            computeDestination.rawValue,
            account.isSignedIn.description,
            String(account.cloudBillingBalance?.availableCredits ?? -1),
            job.language,
            job.script,
            (job.segments ?? []).map(\.text).joined(separator: "\u{1F}"),
            estimateReloadID.uuidString,
        ].joined(separator: "\u{1E}")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    mediaSummary
                    placementSection
                    if cloudComputeSelected, notice != .none {
                        cloudCreditCard
                    } else if placement.needsAuthentication {
                        cloudStorageAccessCard
                    }
                    if let cloudAccessError {
                        Text(cloudAccessError)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Status.errorColor)
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
            footer
        }
        .frame(width: 620, height: 610)
        .background(AppTheme.Background.surfaceColor)
        .colorScheme(.dark)
        .task(id: estimateTaskID) {
            await loadEstimate()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Dub processing options")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                Text("Choose where the session is kept and where dubbed audio is generated.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.xl)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var mediaSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(job.displayTitle)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
            let count = (job.segments ?? []).count
            Text("\(count) script segments · ~\(CloudUsageEstimate.formatDuration(estimatedScriptDuration))")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.medium), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private var estimatedScriptDuration: Double {
        (job.segments ?? []).reduce(0) { total, segment in
            total + estimatedDurationSeconds(segment.text, language: job.language)
        }
    }

    private func estimatedDurationSeconds(_ text: String, language: String) -> Double {
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
        return ceil(Double(compact.count) / rate)
    }

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            placementToggle(
                title: TaskPlacementCopy.keepSessionTitle,
                detail: "Keep an editable cloud session you can reopen on other devices.",
                isOn: Binding(
                    get: { storageDestination == .cloud },
                    set: { storageDestination = $0 ? .cloud : .local }
                )
            )
            placementToggle(
                title: TaskPlacementCopy.processWithTitle,
                detail: TaskPlacementCopy.cloudDubProcessDetail,
                isOn: Binding(
                    get: { computeDestination == .cloud },
                    set: { computeDestination = $0 ? .cloud : .local }
                )
            )
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func placementToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var cloudCreditCard: some View {
        let message = notice.message
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: notice == .none ? "checkmark.circle.fill" : "cloud")
                    .foregroundStyle(noticeColor)
                Text("VoxStudio Cloud")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            }
            if let message {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if estimateError {
                Button("Try again") {
                    estimateReloadID = UUID()
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noticeColor.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(noticeColor.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
        }
    }

    private var cloudStorageAccessCard: some View {
        cloudNotice(
            title: "VoxStudio Cloud",
            detail: account.isSignedIn
                ? "Your session will stay available in VoxStudio Cloud."
                : TaskPlacementCopy.cloudAccountRequired,
            color: AppTheme.Accent.primary
        )
    }

    private func cloudNotice(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            Text(detail)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private var noticeColor: Color {
        switch notice {
        case .insufficient, .lowBalance, .failed:
            AppTheme.Status.warningColor
        case .signIn, .checking:
            AppTheme.Accent.primary
        case .freeUpgrade:
            AppTheme.Accent.primary
        case .none:
            AppTheme.Status.successColor
        }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if isPreparingCloud {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(account.isSignedIn ? "Checking cloud credits…" : TaskPlacementCopy.signingIn)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isPreparingCloud)
            Button(account.isSignedIn || !placement.needsAuthentication ? "Continue" : "Sign in and continue") {
                Task { await prepareAndContinue() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Accent.primary)
            .disabled(continueDisabled || isPreparingCloud)
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppTheme.Spacing.xl)
        .background(AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent))
        .overlay(alignment: .top) { Divider() }
    }

    private func loadEstimate() async {
        guard cloudComputeSelected, account.isSignedIn else {
            estimate = nil
            estimateError = false
            isLoadingEstimate = false
            return
        }
        isLoadingEstimate = true
        estimate = nil
        estimateError = false
        defer { isLoadingEstimate = false }
        do {
            let script = job.script.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = (job.segments ?? []).map(\.text).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let value = try await account.cloudDubUsageEstimate(
                language: job.language == "auto" ? nil : job.language,
                script: script,
                segments: segments
            )
            guard !Task.isCancelled else { return }
            estimate = value
        } catch is CancellationError {
            return
        } catch {
            estimate = nil
            estimateError = true
        }
    }

    private func prepareAndContinue() async {
        guard !isPreparingCloud else { return }
        cloudAccessError = nil
        isPreparingCloud = true
        defer { isPreparingCloud = false }

        if placement.needsAuthentication {
            let result: CloudAccessPreparation
            if let onPrepareCloud {
                result = await onPrepareCloud(placement)
            } else {
                result = await AccountService.shared.ensureCloudAccess()
            }
            switch result {
            case .ready:
                break
            case .cancelled:
                return
            case .failed(let message):
                cloudAccessError = message
                return
            }
        }

        if cloudComputeSelected {
            await loadEstimate()
            guard let estimate, estimate.canAfford, !estimateError else { return }
        }
        onContinue(DubSubmission(placement: placement))
    }
}
