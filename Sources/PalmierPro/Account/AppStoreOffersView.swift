#if MAC_APP_STORE
import SwiftUI
import StoreKit

struct AppStoreOffersView: View {
    let credits: Bool
    @State private var products: [Product] = []
    @State private var error: String?
    @State private var reload = UUID()
    @State private var loading = true
    private let account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if loading { ProgressView() }
            ForEach(products, id: \.id) { product in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(product.displayName)
                    Text(product.description)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Button("\(product.displayPrice)\(product.type == .autoRenewable ? " / month" : "")") {
                        Task { await account.purchaseAppStoreProduct(product.id) }
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(account.isPurchasingAppStoreProduct || !account.isSignedIn)
                    .disabled(product.id == AppStoreProductID.lifetime.rawValue && account.appAccess.license == .lifetime)
                    .disabled(product.type == .autoRenewable && account.isPaid && account.appAccess.subscriptionSource != .appStore)
                }
            }
            if let error {
                Text(error).foregroundStyle(AppTheme.Status.errorColor)
                Button("Retry") { reload = UUID() }
            }
            if !credits {
                Text("Subscriptions renew monthly until cancelled. Lifetime unlocks the app; AI credits are separate.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Button("Restore purchases") { Task { await account.restorePurchases() } }
                    .disabled(account.isPurchasingAppStoreProduct)
                Link("Terms of use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy policy", destination: URL(string: "https://voxstudio.me/privacy.html")!)
            }
        }
        .task(id: reload) {
            loading = true
            error = nil
            do {
                let result = try await AppStorePurchaseProvider.shared.products()
                try Task.checkCancellation()
                products = result.filter {
                    !credits && $0.id == AppStoreProductID.lifetime.rawValue
                }.sorted { $0.price < $1.price }
                if products.isEmpty { error = "Purchases are unavailable right now." }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
#endif
