import SwiftUI

struct AccountPane: View {
    @Bindable var account = AccountService.shared
    @State private var topOffDollars: Int = 20
    @State private var showDeviceManagement = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if let promotion = account.lifetimePromotion, promotion.credits > 0,
               let end = ISO8601DateFormatter().date(from: promotion.endsAt), end > .now {
                Text(L10n.format(
                    "Lifetime includes %@ bonus credits when purchased before %@.",
                    promotion.credits.formatted(),
                    end.formatted(date: .abbreviated, time: .shortened)
                ))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if account.isLoading {
                Text(L10n.string("Loading…"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if account.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }

            if let storeMessage = account.credentialStoreMessage {
                Text(L10n.display(storeMessage))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .frame(maxWidth: AppTheme.Auth.contentWidth, alignment: .leading)
            }
        }
    }

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            trialCountdownSection
#if !MAC_APP_STORE
            licenseKeySection
#endif

            plansSection
#if !MAC_APP_STORE
            if account.featureAccessSnapshot.license != .lifetime {
                SettingsGroup(title: "Lifetime purchase") {
                    AppAccessOffersView(lifetimeOnly: true)
                }
            } else if account.anonymousLifetimePhase != .idle || account.canLinkAnonymousLifetime {
                SettingsGroup(title: "Lifetime purchase") {
                    AppAccessOffersView(statusOnly: true)
                }
            }
#endif
#if MAC_APP_STORE
            AppStoreOffersView(credits: false)
#endif
            if account.canPurchaseCredits {
                creditsSection
            }

#if !MAC_APP_STORE
            if shouldShowDeviceManagement {
                deviceManagementSection
            }
#endif

            Button(L10n.string("Sign out")) {
                Task { await account.signOut() }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
#if !MAC_APP_STORE
        .sheet(isPresented: $showDeviceManagement) {
            LicenseKeyDevicesView(onClose: { showDeviceManagement = false })
        }
#endif
    }

    private func trialSection(_ presentation: TrialPresentation) -> some View {
        SettingsGroup(title: "Free trial") {
            TrialDetailsView(presentation: presentation, showsPurchaseAction: false)
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                }
        }
    }

    @ViewBuilder
    private var unpaidSection: some View {
        SettingsGroup(title: "Choose your access") {
            AppAccessOffersView()
        }
    }

    /// Cloud recurring plan. Independent of Lifetime, which is permanent software ownership on this Mac.
    private var plansSection: some View {
        SettingsGroup(title: "Plans") {
            card {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(account.tier.localizedUpgradeLabel)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)

                        if let status = cloudPlanStatus {
                            Text(status)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if account.account?.user.cancelAtPeriodEnd == true,
                           let date = formattedPeriodEnd {
                            Text(L10n.format("Cancels %@", date))
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    if account.isPaid {
                        Button {
                            Task { await account.manageSubscription() }
                        } label: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(L10n.string("Manage plans"))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(
                                        size: AppTheme.FontSize.xs,
                                        weight: AppTheme.FontWeight.semibold
                                    ))
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(accountSecondaryButtonStyle)
#if MAC_APP_STORE
                        .disabled(account.appAccess.subscriptionSource != .appStore)
#endif
                        .pointerStyle(.link)
                    }
                }

                if showsCloudUpgrade {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(upgradePlans) { plan in
                            cloudUpgradeRow(plan)
                        }
                    }
                }
            }
        }
    }

    private var showsCloudUpgrade: Bool {
        switch account.tier.rawValue {
        case "free", "starter", "basic": return true
        default: return false
        }
    }

    private var upgradePlans: [AvailablePlan] {
        account.availablePlans
            .filter { $0.tier.subscriptionRank > account.tier.subscriptionRank }
            .sorted { $0.tier.subscriptionRank < $1.tier.subscriptionRank }
    }

    private var cloudPlanStatus: String? {
        switch account.tier.rawValue {
        case "free":
            return L10n.string("Upgrade to Starter or Pro for monthly credits.")
        case "starter", "basic":
            return L10n.string("Upgrade for a higher monthly credit allowance.")
        default:
            return nil
        }
    }

    private func cloudUpgradeRow(_ plan: AvailablePlan) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(plan.tier.localizedUpgradeLabel)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.format("$%@/mo", plan.effectiveMonthlyPriceUsd))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .monospacedDigit()
            if let credits = plan.monthlyBudgetCredits {
                Text(L10n.format("%@ credits", credits))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button(L10n.string("Upgrade")) {
                Task { await account.subscribe(tier: plan.tier) }
            }
            .buttonStyle(.capsule(plan.tier.subscriptionRank == upgradePlans.first?.tier.subscriptionRank ? .prominent : .secondary))
            .controlSize(.small)
        }
    }

    private var creditsSection: some View {
        SettingsGroup(title: "Credits") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                remainingCard
                buyCard
            }
        }
    }

    private var remainingCard: some View {
        card {
            cardCaption("Remaining")

            Spacer(minLength: AppTheme.Spacing.sm)

            CreditSummaryView(style: .full)

            Spacer(minLength: AppTheme.Spacing.sm)

            if let date = formattedPeriodEnd {
                Text(L10n.format("Resets %@", date))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private var buyCard: some View {
        card {
            cardCaption("Buy more")

#if MAC_APP_STORE
            AppStoreOffersView(credits: true)
#else
            TopOffField(
                dollars: $topOffDollars,
                fieldFill: AppTheme.Background.raisedColor,
                buttonFill: AnyShapeStyle(AppTheme.Background.raisedColor),
                showsExternalLinkIcon: true
            ) {
                account.buyCredits(dollars: topOffDollars)
            }
#endif

            Text(L10n.string("Purchased credits never expire. Subscription credits reset at renewal."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cardCaption(_ text: String) -> some View {
        Text(L10n.string(text))
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    private var accountSecondaryButtonStyle: CapsuleButtonStyle {
        .init(
            variant: .secondary,
            size: .regular,
            fill: AnyShapeStyle(AppTheme.Background.raisedColor)
        )
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
    }

    private var formattedPeriodEnd: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        return end.formatted(date: .abbreviated, time: .omitted)
    }

    private var signedOutBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            trialCountdownSection
#if !MAC_APP_STORE
            licenseKeySection
#endif
#if MAC_APP_STORE
            AppStoreOffersView(credits: false)
#else
            unpaidSection
#endif
            AccountSignInView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


#if !MAC_APP_STORE
    private var licenseKeySection: some View {
        SettingsGroup(title: L10n.string("License key")) {
            card {
                if isLicenseKeyRedeemed {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AppTheme.Status.successColor)
                            .accessibilityHidden(true)
                        Text(L10n.string("Activated"))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Status.successColor)
                    }
                    Text(L10n.string("License key redeemed on this Mac"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(licenseKeyRedeemedDetail)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("Manage devices…")) {
                        ActivateLicenseWindowController.shared.show()
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                } else {
                    Text(L10n.string("Redeem a license key"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Paste a key from your purchase or reseller to unlock Lifetime on this Mac. Sign-in is optional."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("Redeem license key")) {
                        ActivateLicenseWindowController.shared.show()
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                }
            }
        }
    }

    private var isLicenseKeyRedeemed: Bool {
        LicenseKeyLocalCredential.isPresent()
    }

    private var licenseKeyRedeemedDetail: String {
        L10n.string("This Mac stays unlocked. Use Manage devices to free a slot for another Mac, or re-open activation anytime.")
    }
#endif

    @ViewBuilder
    private var trialCountdownSection: some View {
        if account.trialPresentation != nil {
            SwiftUI.TimelineView(.periodic(from: .now, by: 60.0)) { _ in
                if case let .active(active)? = account.trialPresentation {
                    trialSection(.active(active))
                }
            }
        }
    }

#if !MAC_APP_STORE
    private var shouldShowDeviceManagement: Bool {
        // Show when: local LK credential OR (signed-in AND has linked/owner access)
        if LicenseKeyLocalCredential.isPresent() {
            return true
        }
        // Future: check if user is owner/linked for a license key (requires API support)
        return false
    }

    private var deviceManagementSection: some View {
        SettingsGroup(title: L10n.string("License key")) {
            card {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(L10n.string("Device Management"))
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(L10n.string("View and manage devices activated with your license key"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Button(L10n.string("Manage devices…")) {
                        showDeviceManagement = true
                    }
                    .buttonStyle(accountSecondaryButtonStyle)
                }
            }
        }
    }
#endif
}
