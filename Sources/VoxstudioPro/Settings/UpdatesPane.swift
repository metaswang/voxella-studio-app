import SwiftUI

struct UpdatesPane: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Version"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(AppEnvironmentInfo.version)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Button(L10n.string("Check Now")) {
                    updater.checkForUpdates()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(!updater.canCheckForUpdates || updater.status == .checking)
            }

            statusSection

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            SettingsToggleRow(
                title: "Automatically check for updates",
                subtitle: "Check once a day. New versions are listed here so you can download them yourself.",
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                )
            )
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updater.status {
        case .idle:
            EmptyView()
        case .checking:
            Text(L10n.string("Checking for updates…"))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        case .upToDate:
            Text(L10n.string("You’re up to date."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        case .available(let release):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.format("Version %@ (%@) is available.", release.shortVersion, release.build))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let minimum = release.minimumSystemVersion {
                    Text(L10n.format("Requires macOS %@ or later.", minimum))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Button(L10n.string("Download")) {
                    updater.openDownload()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
            }
        case .unsupportedSystem(let release):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.format(
                    "Version %@ requires macOS %@.",
                    release.shortVersion,
                    release.minimumSystemVersion ?? L10n.string("a newer version")
                ))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.warningColor)
                Text(L10n.string("This Mac does not meet the minimum system requirement, so the download is not offered."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .failed(let message):
            Text(L10n.display(message))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
        }
    }
}
