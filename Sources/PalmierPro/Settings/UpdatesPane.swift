import SwiftUI

struct UpdatesPane: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Version")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(AppEnvironmentInfo.version)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(!updater.canCheckForUpdates)
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            SettingsToggleRow(
                title: "Automatically download and install updates",
                subtitle: "Check once a day and install downloaded updates when VoxStudio quits.",
                isOn: Binding(
                    get: { updater.automaticallyInstallsUpdates },
                    set: { updater.setAutomaticallyInstallsUpdates($0) }
                )
            )
        }
    }
}
