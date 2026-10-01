import SwiftUI

struct VoiceInputSettingsPane: View {
    @Bindable private var preferences = VoiceInputShortcutPreferences.shared

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Voice input shortcut"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string("Show the voice input window from any app."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                if let registrationError = preferences.registrationError {
                    Text(L10n.display(registrationError))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Picker(L10n.string("Voice input shortcut"), selection: $preferences.option) {
                ForEach(VoiceInputShortcutOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            Button(L10n.string("Restore Default"), action: preferences.restoreDefault)
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
    }
}
