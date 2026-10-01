#if MAC_APP_STORE
import AppKit
import Foundation
import StoreKit

enum AppStoreProductID: CaseIterable, Sendable {
    case lifetime

    var rawValue: String {
        switch self {
        case .lifetime:
            Bundle.main.object(forInfoDictionaryKey: "VoxStudioAppStoreLifetimeProductID") as? String ?? ""
        }
    }

    init?(rawValue: String) {
        guard rawValue == Self.lifetime.rawValue else { return nil }
        self = .lifetime
    }
}

actor AppStorePurchaseProvider {
    static let shared = AppStorePurchaseProvider()

    private let api = VoxellaAPIClient.shared

    func products() async throws -> [Product] {
        try await Product.products(for: AppStoreProductID.allCases.map(\.rawValue))
    }

    func purchase(
        _ productID: AppStoreProductID,
        appAccountToken: UUID?
    ) async throws -> String {
        if let appAccountToken {
            // Keep the server preflight before StoreKit. It prevents a real Apple
            // charge when the Mac App Store channel or account is not configured.
            try await api.verifyAppStorePurchase(productID: productID.rawValue, userID: appAccountToken)
        }
        try Task.checkCancellation()
        let products = try await products()
        try Task.checkCancellation()
        guard let product = products.first(where: { $0.id == productID.rawValue }) else {
            throw AppStorePurchaseError.productUnavailable
        }
        let options: Set<Product.PurchaseOption> = if let appAccountToken {
            [.appAccountToken(appAccountToken)]
        } else {
            []
        }
        let result = try await purchaseInCurrentWindow(product, options: options)
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            guard transaction.productID == productID.rawValue else {
                throw AppStorePurchaseError.accountMismatch
            }
            if let appAccountToken {
                guard transaction.appAccountToken == appAccountToken else {
                    throw AppStorePurchaseError.accountMismatch
                }
            }
            // The verified transaction grants local MAS access. Account delivery can
            // retry independently if the API is unavailable after Apple's charge.
            await transaction.finish()
            return verification.jwsRepresentation
        case .pending:
            throw AppStorePurchaseError.pending
        case .userCancelled:
            throw AppStorePurchaseError.cancelled
        @unknown default:
            throw AppStorePurchaseError.unknown
        }
    }

    @discardableResult
    func recover(appAccountToken: UUID) async throws -> AppAccessSnapshot? {
        var firstFailure: Error?
        var latestAccess: AppAccessSnapshot?
        var seenTransactions = Set<UInt64>()
        for await result in Transaction.unfinished {
            try Task.checkCancellation()
            guard case .verified(let transaction) = result else { continue }
            guard transaction.appAccountToken == appAccountToken,
                  AppStoreProductID(rawValue: transaction.productID) != nil else { continue }
            seenTransactions.insert(transaction.id)
            do { latestAccess = try await synchronize(result, appAccountToken: appAccountToken) }
            catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        for await result in Transaction.currentEntitlements {
            try Task.checkCancellation()
            guard case .verified(let transaction) = result else { continue }
            guard AppStoreProductID(rawValue: transaction.productID) != nil else { continue }
            guard transaction.appAccountToken == appAccountToken else { continue }
            guard !seenTransactions.contains(transaction.id) else { continue }
            do {
                latestAccess = try await synchronize(result, appAccountToken: appAccountToken)
            } catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if latestAccess == nil, let firstFailure { throw firstFailure }
        return latestAccess
    }

    func synchronize(_ result: VerificationResult<Transaction>, appAccountToken: UUID) async throws -> AppAccessSnapshot {
        let transaction = try verified(result)
        guard AppStoreProductID(rawValue: transaction.productID) != nil,
              transaction.appAccountToken == appAccountToken else {
            throw AppStorePurchaseError.accountMismatch
        }
        let access = try await api.syncAppStoreTransaction(
            signedTransaction: result.jwsRepresentation, appAccountToken: appAccountToken
        )
        try Task.checkCancellation()
        await transaction.finish()
        return access.snapshot
    }

    private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction): transaction
        case .unverified: throw AppStorePurchaseError.verificationFailed
        }
    }
}

@MainActor
private func purchaseInCurrentWindow(
    _ product: Product,
    options: Set<Product.PurchaseOption>
) async throws -> Product.PurchaseResult {
    let window = NSApp.keyWindow ?? NSApp.mainWindow
        ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
    if #available(macOS 15.2, *), let window {
        return try await product.purchase(confirmIn: window, options: options)
    }
    return try await product.purchase(options: options)
}

enum AppStorePurchaseError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case pending
    case cancelled
    case verificationFailed
    case accountMismatch
    case unknown

    var errorDescription: String? {
        switch self {
        case .productUnavailable: "This purchase is unavailable right now."
        case .pending: "Your purchase is pending approval."
        case .cancelled: "Purchase cancelled."
        case .verificationFailed: "VoxStudio could not verify this purchase."
        case .accountMismatch: "Sign in to the VoxStudio account used for this purchase."
        case .unknown: "VoxStudio could not complete this purchase."
        }
    }
}
#endif
