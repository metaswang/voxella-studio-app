import SwiftUI

struct TrialSidebarStatus: View {
    let isExpanded: Bool

    @Bindable private var account = AccountService.shared
    @State private var showsDetails = false

    var body: some View {
        // Countdown only while trial is actively remaining. Lifetime / expired / verify: no trial clock.
        if case let .active(active)? = account.trialPresentation {
            if isExpanded {
                expandedStatus(.active(active))
            } else {
                collapsedStatus(.active(active))
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

            Button(trialPurchaseLabel) { AppAccessWindow.shared.present() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.link)
                .help(trialPurchaseLabel)
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
        switch presentation {
        case let .active(active): "Trial: \(active.sidebarLabel)"
        case .expired: "Trial ended"
        case .verificationRequired: "Verify trial access"
        }
    }

    private func collapsedText(for presentation: TrialPresentation) -> String {
        if case let .active(active) = presentation { return active.collapsedLabel }
        return "—"
    }

    private func helpText(for presentation: TrialPresentation) -> String {
        switch presentation {
        case let .active(active):
            "Trial ends \(active.endsAt.formatted(date: .abbreviated, time: .shortened))"
        case .expired: "Trial ended. \(trialPurchaseLabel)."
        case .verificationRequired: "Connect to the internet to verify trial access."
        }
    }

    private func foreground(for presentation: TrialPresentation) -> Color {
        switch presentation {
        case let .active(active) where active.usesWarningColor:
            AppTheme.Status.warningColor
        case .expired, .verificationRequired:
            AppTheme.Status.warningColor
        case .active:
            AppTheme.Text.secondaryColor
        }
    }
}

struct TrialDetailsView: View {
    let presentation: TrialPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Free trial")
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            detail

            Button(trialPurchaseLabel) { AppAccessWindow.shared.present() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Auth.contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        switch presentation {
        case let .active(active):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(active.sidebarLabel)
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(active.usesWarningColor ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor)
                Text("Ends \(active.endsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(trialEndDetail)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .expired:
            Text("Your trial has ended. Existing projects remain available.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        case .verificationRequired:
            Text("Connect to the internet to verify your trial access.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var trialEndDetail: String {
#if MAC_APP_STORE
        "After your trial ends, buy Lifetime through the App Store to create new content. Existing projects remain available."
#else
        "After your trial ends, creating new content requires a plan. Existing projects remain available."
#endif
    }
}

private var trialPurchaseLabel: String {
#if MAC_APP_STORE
    "Buy Lifetime"
#else
    "View plans"
#endif
}
