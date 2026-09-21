import SwiftUI

struct TrialSidebarStatus: View {
    let isExpanded: Bool

    @Bindable private var account = AccountService.shared
    @State private var showsDetails = false

    var body: some View {
        // Countdown only while trial is actively remaining. Lifetime / expired / verify: no trial clock.
        if account.trialPresentation != nil {
            SwiftUI.TimelineView(.periodic(from: .now, by: 60.0)) { context in
                if case let .active(active)? = account.trialPresentation {
                    if isExpanded {
                        expandedStatus(.active(active))
                    } else {
                        collapsedStatus(.active(active))
                    }
                }
            }
        }
    }

    private func expandedStatus(_ presentation: TrialPresentation) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Button { showsDetails = true } label: {
                Text(sidebarText(for: presentation))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(foreground(for: presentation))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(L10n.string(key: trialPurchaseLabel)) { purchaseLifetimeOrPresentAccess() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.link)
                .help(L10n.string(key: trialPurchaseLabel))
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            TrialDetailsView(presentation: presentation)
        }
    }

    private func collapsedStatus(_ presentation: TrialPresentation) -> some View {
        Button { showsDetails = true } label: {
            VStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "clock")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(collapsedText(for: presentation))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(foreground(for: presentation))
            .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lgXl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: presentation))
        .accessibilityLabel(helpText(for: presentation))
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            TrialDetailsView(presentation: presentation)
        }
    }

    private func sidebarText(for presentation: TrialPresentation) -> String {
        guard case let .active(active) = presentation else { return "" }
        return L10n.format("Trial: %@", localizedTrialSidebarLabel(active))
    }

    private func collapsedText(for presentation: TrialPresentation) -> String {
        guard case let .active(active) = presentation else { return "" }
        return active.collapsedLabel
    }

    private func helpText(for presentation: TrialPresentation) -> String {
        guard case let .active(active) = presentation else { return "" }
        return L10n.format(
            "Trial ends %@",
            active.endsAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func foreground(for presentation: TrialPresentation) -> Color {
        guard case let .active(active) = presentation else { return AppTheme.Text.secondaryColor }
        return active.usesWarningColor ? AppTheme.Status.warningColor : AppTheme.Text.secondaryColor
    }
}

struct TrialDetailsView: View {
    let presentation: TrialPresentation
    var showsPurchaseAction = true
    @Bindable private var account = AccountService.shared
    @State private var showsSignInAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Free trial")
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            detail

            if showsPurchaseAction {
                Button(L10n.string(key: detailPurchaseLabel)) { purchaseLifetimeOrShowSignIn() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Auth.contentWidth, alignment: .leading)
        .alert(L10n.string("Sign in required"), isPresented: $showsSignInAlert) {
            Button(L10n.string("OK"), role: .cancel) { }
        } message: {
            Text(L10n.string("Sign in to VoxStudio below, then choose Buy Lifetime to open the Apple purchase sheet."))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch presentation {
        case let .active(active):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(localizedTrialSidebarLabel(active))
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(active.usesWarningColor ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor)
                Text(L10n.format("Ends %@", active.endsAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(L10n.string(key: trialEndDetail))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .expired:
            Text(L10n.string("Your trial has ended. Existing projects remain available."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        case .verificationRequired:
            Text(L10n.string("Connect to the internet to verify your trial access."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var trialEndDetail: String {
#if MAC_APP_STORE
        "After your trial ends, buy Lifetime through the App Store to create new content. Existing projects remain available."
#else
        "After your trial ends, choose Lifetime or a monthly plan below to keep creating. Existing projects remain available."
#endif
    }

    private var detailPurchaseLabel: String {
#if MAC_APP_STORE
        account.isSignedIn ? "Buy Lifetime" : "Sign in to buy Lifetime"
#else
        "Choose access"
#endif
    }

    private func purchaseLifetimeOrShowSignIn() {
#if MAC_APP_STORE
        if account.isSignedIn {
            Task { await account.purchaseLifetime() }
        } else {
            showsSignInAlert = true
        }
#else
        AppAccessWindow.shared.present()
#endif
    }

}

@MainActor
func localizedTrialSidebarLabel(_ active: TrialPresentation.Active) -> String {
    if active.remaining < 60 * 60 { return L10n.string("Less than 1 hour left") }
    if active.remaining < 24 * 60 * 60 {
        return L10n.format("%@ hours left", Int(ceil(active.remaining / 3_600)))
    }
    return L10n.format("%@ days left", Int(ceil(active.remaining / 86_400)))
}

@MainActor
private func purchaseLifetimeOrPresentAccess() {
#if MAC_APP_STORE
    if AccountService.shared.isSignedIn {
        Task { await AccountService.shared.purchaseLifetime() }
    } else {
        AppAccessWindow.shared.present()
    }
#else
    AppAccessWindow.shared.present()
#endif
}

private var trialPurchaseLabel: String {
#if MAC_APP_STORE
    "Buy Lifetime"
#else
    "Choose access"
#endif
}
