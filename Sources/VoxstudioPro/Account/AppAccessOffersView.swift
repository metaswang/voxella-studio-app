import AppKit
import SwiftUI

/// The dedicated purchase surface shared by the account settings and the App access window.
///
/// Direct-distribution builds offer account-bound subscriptions and Lifetime
/// checkout with or without sign-in.
struct AppAccessOffersView: View {
    @Bindable private var account = AccountService.shared

#if !MAC_APP_STORE
    var statusOnly = false
    var lifetimeOnly = false
#endif

#if !MAC_APP_STORE
    @State private var signInIntent: PurchaseIntent?
    @State private var showsLicenseDevices = false
#endif

    var body: some View {
#if MAC_APP_STORE
        AppStoreOffersView(credits: false)
#else
        if statusOnly {
            anonymousLifetimeStatus
                .sheet(isPresented: $showsLicenseDevices) {
                    LicenseKeyDevicesView { showsLicenseDevices = false }
                }
        } else if lifetimeOnly {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                lifetimeOffer
                anonymousLifetimeStatus
            }
            .sheet(isPresented: $showsLicenseDevices) {
                LicenseKeyDevicesView { showsLicenseDevices = false }
            }
        } else {
            stripeOffers
        }
#endif
    }

#if !MAC_APP_STORE
    private var stripeOffers: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label(L10n.string("Choose the way you create"), systemImage: "sparkles")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Auth.primaryBackground)
                Text(L10n.string("Own VoxStudio forever or keep your access flexible month to month."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            lifetimeOffer
            anonymousLifetimeStatus

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string("Monthly plans"))
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Spacer(minLength: AppTheme.Spacing.md)
                    Text(L10n.string("Cancel anytime"))
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
                        GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
                    ],
                    spacing: AppTheme.Spacing.sm
                ) {
                    ForEach(monthlyOffers) { offer in
                        monthlyOffer(offer)
                    }
                }
            }

            Label(L10n.string("Secure checkout opens with Stripe. Your subscription is linked to your VoxStudio account."), systemImage: "lock.shield")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $signInIntent) { intent in
            CheckoutSignInSheet(intent: intent)
        }
        .sheet(isPresented: $showsLicenseDevices) {
            LicenseKeyDevicesView { showsLicenseDevices = false }
        }
    }

    private var lifetimeOffer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(AppTheme.Auth.primaryForeground)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(L10n.string("Lifetime"))
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Auth.primaryForeground)
                    Text(L10n.string(key: account.isSignedIn && !account.isOfflineAccount
                        ? "Pay once. This purchase is linked to your VoxStudio account."
                        : "Pay once. This Mac unlocks after payment, and a recovery code restores access without signing in."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Auth.primaryForeground.opacity(AppTheme.Opacity.strong))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(L10n.string("PAY ONCE"))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Auth.primaryBackground)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(Capsule().fill(AppTheme.Auth.primaryForeground))
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                lifetimeBenefit("Unlimited new projects")
                lifetimeBenefit("AI credits separately")
                lifetimeBenefit("Free lifetime software upgrades")
            }

            Button(action: chooseLifetime) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Continue with Stripe"))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular, fill: AnyShapeStyle(AppTheme.Auth.primaryForeground)))
            .disabled(account.isOpeningStripeCheckout)
            .pointerStyle(.link)
        }
        .padding(AppTheme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [
                    AppTheme.Auth.primaryBackground,
                    AppTheme.Auth.primaryBackground.opacity(AppTheme.Opacity.strong),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Auth.primaryForeground.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func lifetimeBenefit(_ text: String) -> some View {
        Label(L10n.string(key: text), systemImage: "checkmark.circle.fill")
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Auth.primaryForeground.opacity(AppTheme.Opacity.strong))
            .symbolRenderingMode(.hierarchical)
    }

    private func monthlyOffer(_ offer: MonthlyOffer) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(offer.tier.localizedUpgradeLabel)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: 0)
                if offer.isRecommended {
                    Text("POPULAR")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Auth.primaryForeground)
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(Capsule().fill(AppTheme.Auth.primaryBackground))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                Text("$\(offer.monthlyPriceUsd)")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .monospacedDigit()
                Text(L10n.string("per month"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Text(localizedDetail(for: offer))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: AppTheme.Spacing.xs)

            Button(action: { chooseSubscription(offer.tier) }) {
                Text(account.isSignedIn
                    ? L10n.string("Continue with Stripe")
                    : L10n.format("Choose %@", offer.tier.localizedUpgradeLabel))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(offer.isRecommended ? .prominent : .secondary, size: .small))
            .disabled(account.isOpeningStripeCheckout)
            .pointerStyle(.link)
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.zoomed(220), alignment: .topLeading)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    offer.isRecommended ? AppTheme.Auth.primaryBackground.opacity(AppTheme.Opacity.strong) : AppTheme.Border.subtleColor,
                    lineWidth: offer.isRecommended ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                )
        }
    }

    private var monthlyOffers: [MonthlyOffer] {
        let liveOffers = Dictionary(
            uniqueKeysWithValues: account.availablePlans.map {
                ($0.tier.rawValue, MonthlyOffer(
                    tier: $0.tier,
                    monthlyPriceUsd: $0.effectiveMonthlyPriceUsd,
                    credits: $0.monthlyBudgetCredits
                ))
            }
        )

        let catalogue = Self.publicMonthlyCatalogue.map { fallback in
            liveOffers[fallback.tier.rawValue] ?? fallback
        }
        let additionalLiveOffers = liveOffers.values.filter { liveOffer in
            !Self.publicMonthlyCatalogue.contains { $0.tier == liveOffer.tier }
        }
        return catalogue + additionalLiveOffers.sorted { $0.monthlyPriceUsd < $1.monthlyPriceUsd }
    }

    private func localizedDetail(for offer: MonthlyOffer) -> String {
        if let credits = offer.credits {
            return L10n.format("%@ credits included every month", credits)
        }
        return L10n.string(key: offer.detail)
    }

    private static let publicMonthlyCatalogue: [MonthlyOffer] = [
        .init(tier: AccountTier(rawValue: "starter"), monthlyPriceUsd: 5, credits: 500),
        .init(tier: AccountTier(rawValue: "pro"), monthlyPriceUsd: 15, credits: nil),
    ]

    private func chooseLifetime() {
        Task { await account.purchaseLifetime() }
    }

    @ViewBuilder
    private var anonymousLifetimeStatus: some View {
        switch account.anonymousLifetimePhase {
        case .idle:
            if account.canLinkAnonymousLifetime {
                Button(L10n.string("Link to current account")) {
                    Task { await account.linkAnonymousLifetimeToCurrentAccount() }
                }
                .buttonStyle(.capsule(.secondary, size: .small))
            }
        case .awaitingPayment:
            statusCopy("Finish checkout in your browser, then return to VoxStudio.")
            statusActions(includeCancel: true)
        case .waitingForConfirmation:
            statusCopy("Stripe is still confirming this payment. You can check again.")
            statusActions(includeCancel: true)
        case .unlocked(let recoveryCode):
            recoveryCodeView(recoveryCode, activated: true)
        case .needsActivation(let recoveryCode):
            recoveryCodeView(recoveryCode, activated: false)
        case .failed:
            EmptyView()
        }
    }

    private func recoveryCodeView(_ recoveryCode: String, activated: Bool) -> some View {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string(key: activated
                    ? "Lifetime is unlocked on this Mac"
                    : "Lifetime payment confirmed. Activate the recovery code to unlock this Mac."))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Save this recovery code. It restores Lifetime on this Mac or another Mac without signing in."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recoveryCode)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button(L10n.string("Copy recovery code")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recoveryCode, forType: .string)
                        account.noteAnonymousLifetime(L10n.string("Recovery code copied."))
                    }
                    Button(L10n.string("Save recovery code…")) { saveRecoveryCode(recoveryCode) }
                    if activated {
                        Button(L10n.string("Manage devices")) { showsLicenseDevices = true }
                    }
                }
                if !activated {
                    Button(L10n.string("Retry activation")) {
                        Task { await account.checkAnonymousLifetimePayment() }
                    }
                }
                if account.canLinkAnonymousLifetime {
                    Button(L10n.string("Link to current account")) {
                        Task { await account.linkAnonymousLifetimeToCurrentAccount() }
                    }
                }
                if activated {
                    Button(L10n.string("I've saved the recovery code")) {
                        account.acknowledgeAnonymousRecoveryCode()
                    }
                }
            }
    }

    private func statusCopy(_ key: String) -> some View {
        Text(L10n.string(key: key))
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusActions(includeCancel: Bool) -> some View {
        HStack {
            Button(L10n.string("Check payment status")) {
                Task { await account.checkAnonymousLifetimePayment() }
            }
            if includeCancel {
                Button(L10n.string("Cancel checkout")) {
                    Task { await account.cancelAnonymousLifetimeCheckout() }
                }
            }
        }
    }

    private func saveRecoveryCode(_ code: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoxStudio-Lifetime-Recovery-Code.txt"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try code.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in account.noteAnonymousLifetime(error.localizedDescription) }
            }
        }
    }

    private func chooseSubscription(_ tier: AccountTier) {
        if account.isSignedIn {
            Task { await account.subscribe(tier: tier) }
        } else {
            signInIntent = .subscription(tier.rawValue)
        }
    }

    private enum PurchaseIntent: Identifiable {
        case lifetime
        case subscription(String)

        var id: String {
            switch self {
            case .lifetime: "lifetime"
            case .subscription(let tier): "subscription-\(tier)"
            }
        }

        var title: String {
            switch self {
            case .lifetime: "Lifetime"
            case .subscription(let tier): AccountTier(rawValue: tier).upgradeLabel
            }
        }
    }

    private struct MonthlyOffer: Identifiable {
        let tier: AccountTier
        let monthlyPriceUsd: Int
        let credits: Int?

        var id: String { tier.rawValue }
        var name: String { tier.upgradeLabel }
        var isRecommended: Bool { tier.rawValue == "pro" }
        var detail: String {
            if let credits {
                return "\(credits.formatted()) credits included every month"
            }
            return isRecommended
                ? "More capacity for frequent creation"
                : "Flexible monthly access to VoxStudio"
        }
    }

    private struct CheckoutSignInSheet: View {
        let intent: PurchaseIntent
        @Environment(\.dismiss) private var dismiss
        @Bindable private var account = AccountService.shared
        @State private var hasStartedCheckout = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Label(L10n.string("One quick step"), systemImage: "lock.fill")
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Auth.primaryBackground)
                        Text(L10n.format("Sign in to continue with %@", L10n.string(key: intent.title)))
                            .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(L10n.string("We use your account to link the Stripe purchase and restore access on this Mac."))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AccountSignInView()
                }
                .padding(AppTheme.Spacing.xxl)
                .frame(width: AppTheme.zoomed(440), alignment: .leading)
            }
            .onChange(of: account.isSignedIn) { _, signedIn in
                guard signedIn, !hasStartedCheckout else { return }
                hasStartedCheckout = true
                dismiss()
                Task {
                    switch intent {
                    case .lifetime:
                        await account.purchaseLifetime()
                    case .subscription(let tier):
                        await account.subscribe(tier: AccountTier(rawValue: tier))
                    }
                }
            }
        }
    }
#endif
}
