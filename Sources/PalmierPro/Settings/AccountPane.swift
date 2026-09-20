import SwiftUI

struct AccountPane: View {
    @Bindable var account = AccountService.shared
    @State private var topOffDollars: Int = 20
    @State private var showDeviceManagement = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if let promotion = account.lifetimePromotion, promotion.credits > 0,
               let end = ISO8601DateFormatter().date(from: promotion.endsAt), end > .now {
                Text("Lifetime includes \(promotion.credits.formatted()) bonus credits when purchased before \(end.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if account.isLoading {
                Text("Loading…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if account.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }

            if let error = account.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
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

            if account.isPaid || account.appAccess.license == .lifetime {
                subscriptionSection
#if MAC_APP_STORE
                AppStoreOffersView(credits: false)
#endif
                if account.canPurchaseCredits {
                    creditsSection
                }
            } else {
                unpaidSection
            }

#if !MAC_APP_STORE
            if shouldShowDeviceManagement {
                deviceManagementSection
            }
#endif

            Button("Sign out") {
                Task { await account.signOut() }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDeviceManagement) {
            LicenseKeyDevicesView(onClose: { showDeviceManagement = false })
        }
    }

    private func trialSection(_ presentation: TrialPresentation) -> some View {
        SettingsGroup(title: "Free trial") {
            TrialDetailsView(presentation: presentation)
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                }
        }
    }

    @ViewBuilder
    private var unpaidSection: some View {
        SettingsGroup(title: "Subscription") {
#if MAC_APP_STORE
            AppStoreOffersView(credits: false)
#else
            if account.availablePlans.isEmpty {
                Text("No subscription plans are available.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                VStack(spacing: AppTheme.Spacing.md) {
                    if account.isAppAccessEnforced {
                        lifetimeCard
                    }
                    ForEach(Array(account.availablePlans.enumerated()), id: \.element.id) { index, plan in
                        planCard(plan: plan, isPrimary: index == 0)
                    }
                }

                Text("Credits cover AI generation and chat.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
#endif
        }
    }

#if !MAC_APP_STORE
    private var lifetimeCard: some View {
        card {
            cardCaption("Lifetime")
            Text("Own the Mac app permanently. AI credits are available separately.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Button("Buy Lifetime") {
                Task { await account.purchaseLifetime() }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
#if MAC_APP_STORE
            Button("Restore purchases") {
                Task { await account.restorePurchases() }
            }
            .buttonStyle(.borderless)
#endif
        }
    }

    private func planCard(plan: AvailablePlan, isPrimary: Bool) -> some View {
        card {
            cardCaption(plan.tier.planLabel)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                Text("$\(plan.effectiveMonthlyPriceUsd)")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if plan.hasDiscount {
                    Text("$\(plan.monthlyPriceUsd)")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .strikethrough()
                }
                Text("/ month")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            if let credits = plan.monthlyBudgetCredits {
                Text("\(credits.formatted()) credits / month")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .monospacedDigit()
            }

            Spacer(minLength: AppTheme.Spacing.xs)

            upgradeButton(for: plan, isPrimary: isPrimary)
        }
    }

    private func upgradeButton(for plan: AvailablePlan, isPrimary: Bool) -> some View {
        let label = "Upgrade to \(plan.tier.upgradeLabel)"
        return Button {
            Task { await account.subscribe(tier: plan.tier) }
        } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(.capsule(
            isPrimary ? .prominent : .secondary,
            size: .regular,
            fill: isPrimary ? nil : AnyShapeStyle(AppTheme.Background.raisedColor)
        ))
        .pointerStyle(.link)
    }

#endif

    private var subscriptionSection: some View {
        SettingsGroup(title: "Subscription") {
            card {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(account.appAccessLabel)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)

                        if account.account?.user.cancelAtPeriodEnd == true,
                           let date = formattedPeriodEnd {
                            Text("Cancels \(date)")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Button {
                        Task { await account.manageSubscription() }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text("Manage subscription")
                            Image(systemName: "arrow.up.right")
                                .font(.system(
                                    size: AppTheme.FontSize.xs,
                                    weight: AppTheme.FontWeight.semibold
                                ))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(accountSecondaryButtonStyle)
                    .disabled(!account.isPaid)
#if MAC_APP_STORE
                    .disabled(account.appAccess.subscriptionSource != .appStore)
#endif
                    .pointerStyle(.link)
                }
            }
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
                Text("Resets \(date)")
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

            Text("Purchased credits never expire. Subscription credits reset at renewal.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cardCaption(_ text: String) -> some View {
        Text(text)
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
            AccountSignInView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


#if !MAC_APP_STORE
    private var licenseKeySection: some View {
        SettingsGroup(title: "License key") {
            card {
                if isLicenseKeyRedeemed {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AppTheme.Status.successColor)
                            .accessibilityHidden(true)
                        Text("Activated")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Status.successColor)
                    }
                    Text("License key redeemed on this Mac")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(licenseKeyRedeemedDetail)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let offlineUntil = licenseKeyOfflineValidUntilText {
                        Text(offlineUntil)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Button("Manage devices…") {
                        ActivateLicenseWindowController.shared.show()
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                } else {
                    Text("Redeem a license key")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Paste a key from your purchase or reseller to unlock Lifetime on this Mac. Sign-in is optional.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Redeem license key") {
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
        "This Mac stays unlocked. Use Manage devices to free a slot for another Mac, or re-open activation anytime."
    }

    private var licenseKeyOfflineValidUntilText: String? {
        guard let record = try? LicenseKeyLocalCredential.load(),
              record.isChronologicallyValid(at: .now) else { return nil }
        let formatted = record.expiresAt.formatted(date: .abbreviated, time: .shortened)
        return "Offline access valid until \(formatted)"
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
        SettingsGroup(title: "License Key") {
            card {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Device Management")
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text("View and manage devices activated with your license key")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Button("Manage Devices…") {
                        showDeviceManagement = true
                    }
                    .buttonStyle(accountSecondaryButtonStyle)
                }
            }
        }
    }
#endif
}
