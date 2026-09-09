import SwiftUI

struct LanguageSettingsPane: View {
    @Bindable private var localization = AppLocalization.shared

    var body: some View {
        SettingsSection(title: L10n.string("Language")) {
            Picker(L10n.string("Application Language"), selection: $localization.selection) {
                Text(localization.displayName(for: .system))
                    .tag(AppLanguage.system)
                ForEach(localization.availableLanguages) { language in
                    Text(localization.displayName(for: language))
                        .tag(language)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint(L10n.string("Choose the language VoxStudio uses after restarting."))

            Text(L10n.string("Choose the language VoxStudio uses after restarting. Follow System Language uses the first preferred language in macOS."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            if localization.requiresRestart {
                Label(L10n.string("Restart VoxStudio to apply your language choice."), systemImage: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
