import SwiftUI

enum TranscriptionAIAccessPromptPolicy {
    static func shouldPresent(
        compute: TaskComputeDestination,
        hasUsableLLM: Bool
    ) -> Bool {
        compute == .local && !hasUsableLLM
    }
}

struct TranscriptionAIUpgradePrompt: View {
    let onContinueWithoutAI: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Image(systemName: "text.badge.sparkles")
                .font(.system(size: AppTheme.IconSize.xl, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.primary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Make the first transcript ready to use"))
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string("Your Mac can create a basic transcript now. Unlock VoxStudio AI to turn raw speech recognition into polished text and production-ready subtitles automatically."))
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                benefit("Restore punctuation and correct likely recognition mistakes", systemImage: "checkmark.seal.fill")
                benefit("Create readable subtitle timing and line breaks", systemImage: "captions.bubble.fill")
                benefit("Unlock translation, summaries, and AI-assisted workflows", systemImage: "sparkles")
            }

            VStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    SettingsWindowController.shared.show(tab: .account)
                    dismiss()
                } label: {
                    Label(L10n.string(account.isSignedIn ? "Upgrade for polished transcripts" : "Explore VoxStudio plans"), systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))

                Button {
                    SettingsWindowController.shared.show(tab: .ai)
                    dismiss()
                } label: {
                    Label(L10n.string("Use my own API key"), systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))

                Button(L10n.string("Continue with basic transcript")) {
                    dismiss()
                    onContinueWithoutAI()
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Text(L10n.string("Basic transcription still includes timestamped transcript segments. AI subtitles, correction, punctuation, translation, and summaries are skipped."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: AppTheme.Settings.contentMaxWidth)
        .background(AppTheme.Background.surfaceColor)
    }

    private func benefit(_ title: String, systemImage: String) -> some View {
        Label(L10n.display(title), systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }
}
