import SwiftUI

struct AppearanceSettingsPane: View {
    @Bindable private var preferences = AppAppearancePreferences.shared

    var body: some View {
        SettingsSection(title: L10n.string("Appearance")) {
            Picker(L10n.string("Appearance"), selection: $preferences.selection) {
                ForEach(AppAppearanceChoice.allCases) { choice in
                    Text(L10n.string(choice.label)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(L10n.string("Appearance"))

            Text(L10n.string("Match macOS appearance automatically."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }
}

private extension AppAppearanceChoice {
    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }
}
