import SwiftUI

struct LocalModelRequirementCard: View {
    let plan: LocalModelInstallPlan
    @Bindable private var manager = LocalModelManager.shared

    private var status: LocalPreparationStatus {
        manager.preparationStatus(for: plan.items.map(\.id))
    }

    var body: some View {
        if !plan.missingItems.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                Label(L10n.string("Prepare speech features"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Speech processing runs on your Mac. The required resources are prepared once, verified, and reused for future files."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(L10n.string("First-time download") + ": " + LocalModelInstallPlan.formatBytes(plan.additionalBytes))
                    .font(.system(size: AppTheme.FontSize.sm))

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(plan.items) { item in
                        let modelState = manager.state(for: item.id)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: stateIcon(for: modelState))
                                .foregroundStyle(stateColor(for: modelState))
                                .frame(width: 16)
                            Text(L10n.display(item.userFacingTitle))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .lineLimit(1)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Text("\(L10n.string(modelStateLabel(for: modelState))) · \(item.sizeLabel)")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .lineLimit(1)
                        }
                    }
                }

                if manager.isPreparing(plan) {
                    ProgressView(value: status.progress)
                    Text(L10n.display(status.userFacingMessage))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        }
    }

    private func stateIcon(for state: LocalModelDownloadState) -> String {
        switch state {
        case .installed: "checkmark.circle.fill"
        case .queued, .downloading, .verifying: "arrow.down.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .notInstalled: "circle"
        }
    }

    private func stateColor(for state: LocalModelDownloadState) -> Color {
        switch state {
        case .installed: AppTheme.Status.successColor
        case .queued, .downloading, .verifying: AppTheme.Accent.primary
        case .failed: AppTheme.Status.errorColor
        case .notInstalled: AppTheme.Text.mutedColor
        }
    }

    private func modelStateLabel(for state: LocalModelDownloadState) -> String {
        switch state {
        case .installed: "Ready"
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .failed: "Retry"
        case .notInstalled: "Not downloaded"
        }
    }
}
