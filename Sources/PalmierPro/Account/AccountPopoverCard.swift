import SwiftUI

/// Compact account summary shown when the user clicks the IdentityStrip avatar.
struct AccountPopoverCard: View {
    @Bindable private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    private static let cardWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            identityBlock

            // Signed-in plan, Lifetime device credential, or active trial countdown (signed-out OK).
            if account.isSignedIn
                || account.featureAccessSnapshot.license == .lifetime
                || account.hasLocalLifetimeCredential
                || activeTrialPresentation != nil {
                Divider().overlay(AppTheme.Border.subtleColor)
                planBlock
            }

            Divider().overlay(AppTheme.Border.subtleColor)
            footerRow
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: Self.cardWidth)
        .focusEffectDisabled()
    }

    // MARK: - Identity (mirrors IdentityStrip layout)

    private var identityBlock: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            UserAvatar(
                diameter: AppTheme.IconSize.xl,
                fontSize: AppTheme.FontSize.mdLg
            )
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.display(account.displayPrimaryText))
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = account.displaySecondaryText {
                    Text(secondary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Plan + credit info

    private var planTitle: String {
        account.localizedAppAccessLabel
    }

    /// Lifetime is Mac software ownership. The cloud plan stays visible beside it.
    private var showsSoftwareLifetimeBesideCloudPlan: Bool {
        account.featureAccessSnapshot.license == .lifetime || account.hasLocalLifetimeCredential
    }

    private var planBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(planTitle)
                        .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    if account.isSignedIn, showsSoftwareLifetimeBesideCloudPlan {
                        Text(account.tier.localizedPlanLabel)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                Spacer(minLength: 0)
                if account.account?.user.cancelAtPeriodEnd == true,
                   let date = formattedPeriodEnd {
                    Text(L10n.format("Cancels %@", date))
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(.orange)
                }
            }

            if activeTrialPresentation != nil {
                SwiftUI.TimelineView(.periodic(from: .now, by: 60.0)) { _ in
                    if let active = activeTrialPresentation {
                        trialCountdownBlock(active: active)
                    }
                }
            }

            if account.isSignedIn {
                creditsBlock
            }

            if account.isSignedIn, !account.isPaid {
                upgradeBlock
            }
        }
    }

    @ViewBuilder
    private func trialCountdownBlock(active: TrialPresentation.Active) -> some View {
        Button { AppAccessWindow.shared.present() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "clock")
                Text(L10n.format("Trial: %@", localizedTrialSidebarLabel(active)))
                Spacer(minLength: 0)
                Text(L10n.string(key: trialActionLabel))
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(active.usesWarningColor ? AppTheme.Status.warningColor : AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
        .help(L10n.string(key: trialActionLabel))

        Text(L10n.format("Ends %@", active.endsAt.formatted(date: .abbreviated, time: .shortened)))
            .font(.system(size: AppTheme.FontSize.xxs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    /// Countdown UI only — expired / verify / Lifetime must not show a trial clock.
    private var activeTrialPresentation: TrialPresentation.Active? {
        if case let .active(active)? = account.trialPresentation { return active }
        return nil
    }

    private var trialActionLabel: String {
#if MAC_APP_STORE
        "Buy Lifetime"
#else
        "View plans"
#endif
    }

    @ViewBuilder
    private var upgradeBlock: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            ForEach(Array(account.availablePlans.enumerated()), id: \.element.id) { index, plan in
                planRow(plan: plan, isPrimary: index == 0)
            }
        }
    }

    @ViewBuilder
    private func planRow(plan: AvailablePlan, isPrimary: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(plan.tier.localizedUpgradeLabel)
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text(L10n.format("$%@/mo", plan.effectiveMonthlyPriceUsd))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .monospacedDigit()

            if plan.hasDiscount {
                Text("$\(plan.monthlyPriceUsd)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .strikethrough()
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if let credits = plan.monthlyBudgetCredits {
                Text(creditsShortLabel(credits))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            upgradeActionButton(tier: plan.tier, isPrimary: isPrimary)
        }
    }

    @ViewBuilder
    private func upgradeActionButton(tier: AccountTier, isPrimary: Bool) -> some View {
        if isPrimary {
            Button(L10n.string("Upgrade")) {
                Task { await account.subscribe(tier: tier) }
                dismiss()
            }
            .buttonStyle(.capsule(.prominent))
            .controlSize(.small)
        } else {
            Button(L10n.string("Upgrade")) {
                Task { await account.subscribe(tier: tier) }
                dismiss()
            }
            .buttonStyle(.capsule(.secondary))
            .controlSize(.small)
        }
    }

    private func creditsShortLabel(_ credits: Int) -> String {
        if credits >= 1000, credits % 1000 == 0 {
            return L10n.format("%@k credits", credits / 1000)
        }
        return L10n.format("%@ credits", credits)
    }

    @ViewBuilder
    private var creditsBlock: some View {
        if let budget = account.budgetCredits {
            let left = max(0, budget - account.spentCredits)
            let remaining = budget > 0 ? min(1.0, Double(left) / Double(budget)) : 0
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ProgressView(value: remaining)
                    .progressViewStyle(.linear)
                    .tint(barColor(remaining))
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(L10n.format("%@ / %@ credits", left, budget))
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: 0)
                    if let date = formattedPeriodEnd {
                        Text(L10n.format("Resets %@", date))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
        }
    }

    private func barColor(_ remaining: Double) -> Color {
        switch remaining {
        case ..<0.05: return .red
        case ..<0.25: return .orange
        default: return AppTheme.Accent.primary
        }
    }

    // MARK: - Footer (Settings + Sign in / Sign out)

    private var footerRow: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            footerButton(label: "Settings", systemImage: "gearshape") {
                SettingsWindowController.shared.show()
                dismiss()
            }
            footerButton(label: "Feedback", systemImage: "bubble.left.and.bubble.right") {
                FeedbackWindowController.shared.show()
                dismiss()
            }
            if account.isSignedIn {
                footerButton(label: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await account.signOut() }
                    dismiss()
                }
            } else {
                footerButton(label: account.isSigningIn ? "Signing in…" : "Sign in with Google", systemImage: "person.crop.circle") {
                    Task { await account.signInWithGoogle() }
                    dismiss()
                }
                .disabled(account.isSigningIn)
                footerButton(label: account.isSigningIn ? "Signing in…" : "Sign in with Apple", systemImage: "apple.logo") {
                    Task { await account.signInWithApple() }
                    dismiss()
                }
                .disabled(account.isSigningIn)
            }
        }
    }

    private func footerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd))
                Text(L10n.string(key: label))
                    .font(.system(size: AppTheme.FontSize.sm))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

    private var formattedPeriodEnd: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        return end.formatted(date: .abbreviated, time: .omitted)
    }
}
