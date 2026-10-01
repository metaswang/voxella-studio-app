import SwiftUI

@MainActor
struct FeatureAccessPrompt: View {
    let feature: AccountFeature
    let access: AccountFeatureAccess
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var account = AccountService.shared
    @State private var isWorking = false
    @State private var workingTier: AccountTier?

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

            actions
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
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

                if feature != .meetBot {
                    cancelButton
                }
            }
        case .upgradeRequired:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if eligiblePlans.isEmpty {
                    Text(L10n.string("No subscription plans are available right now."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.string("Choose a plan. Every option unlocks Meet Bot and Google Calendar."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        ForEach(Array(eligiblePlans.enumerated()), id: \.element.id) { index, plan in
                            planCard(plan, isPrimary: index == 0)
                        }
                    }
                }

                Button {
                    SettingsWindowController.shared.show(tab: .account)
                    dismiss()
                } label: {
                    Text(L10n.string("Open Account Settings"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isWorking)
            }
        case .allowed:
            EmptyView()
        }
    }

    private var eligiblePlans: [AvailablePlan] {
        guard case let .upgradeRequired(minimumPlan) = access else { return [] }
        return account.availablePlans
            .filter { $0.tier.satisfies(minimumPlan) }
            .sorted {
                if $0.tier.subscriptionRank != $1.tier.subscriptionRank {
                    return $0.tier.subscriptionRank < $1.tier.subscriptionRank
                }
                return $0.effectiveMonthlyPriceUsd < $1.effectiveMonthlyPriceUsd
            }
    }

    private func planCard(_ plan: AvailablePlan, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(plan.tier.localizedPlanLabel)
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Spacer(minLength: AppTheme.Spacing.sm)

                if plan.hasDiscount {
                    Text("$\(plan.monthlyPriceUsd)")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .strikethrough()
                        .monospacedDigit()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                Text("$\(plan.effectiveMonthlyPriceUsd)")
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .monospacedDigit()
                Text(L10n.string("per month"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            if let credits = plan.monthlyBudgetCredits {
                Label(
                    String(
                        format: L10n.string("%@ credits each month"),
                        credits.formatted()
                    ),
                    systemImage: "sparkles"
                )
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }

            Button {
                subscribe(to: plan.tier)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if workingTier == plan.tier {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    Text(String(
                        format: L10n.string("Upgrade to %@"),
                        plan.tier.localizedUpgradeLabel
                    ))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(
                isPrimary ? .prominent : .secondary,
                size: .regular,
                fill: isPrimary ? nil : AnyShapeStyle(AppTheme.Background.surfaceColor)
            ))
            .disabled(isWorking || plan.planID == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lg)
        .themedSurface(
            AppTheme.Background.raisedColor,
            cornerRadius: AppTheme.Radius.md,
            border: isPrimary ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor
        )
    }

    private func subscribe(to tier: AccountTier) {
        Task { @MainActor in
            isWorking = true
            workingTier = tier
            await account.subscribe(tier: tier)
            isWorking = false
            workingTier = nil
            guard account.lastError == nil else { return }
            SettingsWindowController.shared.show(tab: .account)
            dismiss()
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
                : L10n.string("Sign in to send a visible notetaker to Google Meet, Teams, or Zoom. Remote notetaker requires a Starter plan or higher.")
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
