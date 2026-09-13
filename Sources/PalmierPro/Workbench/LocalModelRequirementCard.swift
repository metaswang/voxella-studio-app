import SwiftUI

struct LocalModelRequirementCard: View {
    let plan: LocalModelInstallPlan
    @Bindable private var manager = LocalModelManager.shared

    var body: some View {
        if !plan.missingItems.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label(L10n.string("Prepare this feature on your Mac"), systemImage: "arrow.down.circle")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("The required resources will download before this task starts. You only need to download them once."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(L10n.string("Estimated download") + ": " + LocalModelInstallPlan.formatBytes(plan.additionalBytes))
                    .font(.system(size: AppTheme.FontSize.sm))
                if manager.isPreparing(plan) {
                    ProgressView(value: manager.preparationStatus(for: plan.items.map(\.id)).progress)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        }
    }
}
