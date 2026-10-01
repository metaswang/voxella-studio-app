#if MAC_APP_STORE
import SwiftUI
import StoreKit

struct AppStoreOffersView: View {
    let credits: Bool
    @State private var products: [Product] = []
    @State private var error: String?
    @State private var reload = UUID()
    @State private var loading = true
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            if credits {
                Text(L10n.string("Credit purchases are not available in the Mac App Store version."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if loading || !account.hasLoadedStoreKitLifetime {
                offerLoadingCard
            } else if let product = products.first {
                lifetimeCard(product)
            } else {
                unavailableCard
            }

            if !credits {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button(L10n.string("Restore purchases")) { Task { await account.restorePurchases() } }
                        .buttonStyle(.borderless)
                        .disabled(account.isPurchasingAppStoreProduct)
                    Spacer(minLength: 0)
                    Link(L10n.string("Terms"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Link(L10n.string("Privacy"), destination: URL(string: "https://voxstudio.me/privacy.html")!)
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .task(id: reload) {
            guard !credits else {
                loading = false
                return
            }
            loading = true
            error = nil
            do {
                let result = try await AppStorePurchaseProvider.shared.products()
                try Task.checkCancellation()
                products = result
                    .filter { $0.id == AppStoreProductID.lifetime.rawValue }
                    .sorted { $0.price < $1.price }
                if products.isEmpty { error = "The App Store price is not available right now." }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private var offerLoadingCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text(L10n.string("Loading App Store pricing…"))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lgXl)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.lg)
    }

    private func lifetimeCard(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Lifetime access"))
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("One-time Mac access with free software upgrades for life."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.md)
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                    if isLifetimePurchased {
                        Label(L10n.string("Purchased"), systemImage: "checkmark.seal.fill")
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Status.successColor)
                    } else {
                        Text(product.displayPrice)
                            .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(L10n.string("one time"))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }

            Divider().overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                featureRow("Unlimited new projects")
                featureRow("Existing projects stay available")
                featureRow("AI credits purchased separately")
                featureRow("Free lifetime software upgrades")
            }

            if isLifetimePurchased {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: AppTheme.FontSize.lg))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(L10n.string("Lifetime purchased"))
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                        Text(L10n.string("This Mac already has Lifetime access."))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.Status.successColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.md)
                .background(
                    AppTheme.Status.successColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(
                            AppTheme.Status.successColor.opacity(0.3),
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
                .accessibilityElement(children: .combine)
                if account.anonymousLifetimeLinkJWS != nil {
                    Button(L10n.string("Link this purchase to the current account")) {
                        Task { await account.linkAnonymousLifetimePurchase() }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(account.isLinkingAppStoreLifetime)
                }
            } else {
                Button {
                    Task { await account.purchaseAppStoreProduct(product.id) }
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if account.isPurchasingAppStoreProduct {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(L10n.string("Buy Lifetime"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(account.isPurchasingAppStoreProduct)
            }

            if !account.isSignedIn && account.hasLocalLifetimeCredential {
                Label(L10n.string("Sign in below to link the purchase to your VoxStudio account."), systemImage: "person.crop.circle")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.lg)
    }

    private var isLifetimePurchased: Bool {
        account.hasLocalLifetimeCredential || account.featureAccessSnapshot.license == .lifetime
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(L10n.string("Lifetime purchase unavailable"), systemImage: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.display(error ?? "The App Store price is not available right now."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Button(L10n.string("Try again")) { reload = UUID() }
                .buttonStyle(.capsule(.secondary, size: .regular))
        }
        .padding(AppTheme.Spacing.lgXl)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.lg)
    }

    private func featureRow(_ text: String) -> some View {
        Label(L10n.display(text), systemImage: "checkmark.circle.fill")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .symbolRenderingMode(.hierarchical)
    }
}
#endif
