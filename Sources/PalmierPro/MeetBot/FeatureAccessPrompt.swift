import SwiftUI

@MainActor
struct FeatureAccessPrompt: View {
    let feature: AccountFeature
    let access: AccountFeatureAccess
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var account = AccountService.shared
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: AppTheme.IconSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.primary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(message)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = account.lastError, isWorking == false {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: AppTheme.Settings.contentMaxWidth)
        .background(AppTheme.Background.surfaceColor)
    }

    @ViewBuilder
    private var actions: some View {
        switch access {
        case .signedOut:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Button {
                    signIn(provider: .google)
                } label: {
                    Label(L10n.string("Sign in with Google"), systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(isWorking || account.isSigningIn)

                Button {
                    signIn(provider: .apple)
                } label: {
                    Label(L10n.string("Sign in with Apple"), systemImage: "apple.logo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isWorking || account.isSigningIn)

                cancelButton
            }
        case .upgradeRequired:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Button {
                    Task { @MainActor in
                        isWorking = true
                        await account.subscribeToMinimumPlan(for: feature)
                        isWorking = false
                        SettingsWindowController.shared.show(tab: .account)
                        dismiss()
                    }
                } label: {
                    Label(L10n.string("Upgrade to Starter"), systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(isWorking)

                Button {
                    SettingsWindowController.shared.show(tab: .account)
                    dismiss()
                } label: {
                    Text(L10n.string("Open Account Settings"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isWorking)

                cancelButton
            }
        case .allowed:
            EmptyView()
        }
    }

    private var title: String {
        switch access {
        case .signedOut:
            feature == .calendarSettings
                ? L10n.string("Sign in to use Google Calendar")
                : L10n.string("Sign in to use Meet Bot")
        case .upgradeRequired:
            feature == .calendarSettings
                ? L10n.string("Upgrade to unlock Google Calendar")
                : L10n.string("Upgrade to unlock Meet Bot")
        case .allowed:
            ""
        }
    }

    private var message: String {
        switch access {
        case .signedOut:
            return feature == .calendarSettings
                ? L10n.string("Sign in to connect Google Calendar and configure Meet Bot automation.")
                : L10n.string("Sign in to send a visible bot to Google Meet, Teams, or Zoom meetings.")
        case .upgradeRequired:
            return L10n.string("Meet Bot and Google Calendar require a Starter plan or higher.")
        case .allowed:
            return ""
        }
    }

    private var cancelButton: some View {
        Button(L10n.string("Cancel")) {
            dismiss()
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .disabled(isWorking)
    }

    private func signIn(provider: SignInProvider) {
        Task { @MainActor in
            isWorking = true
            switch provider {
            case .google:
                await account.signInWithGoogle()
            case .apple:
                await account.signInWithApple()
            }
            isWorking = false
            onRetry()
        }
    }

    private enum SignInProvider {
        case google
        case apple
    }
}
