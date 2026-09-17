#if MAC_APP_STORE
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
        appAccountToken: UUID
    ) async throws -> AppAccessSnapshot? {
        try await api.verifyAppStorePurchase(productID: productID.rawValue, userID: appAccountToken)
        try Task.checkCancellation()
        let products = try await products()
        try Task.checkCancellation()
        guard let product = products.first(where: { $0.id == productID.rawValue }) else {
            throw AppStorePurchaseError.productUnavailable
        }
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            guard transaction.productID == productID.rawValue,
                  transaction.appAccountToken == appAccountToken else {
                throw AppStorePurchaseError.accountMismatch
            }
            let access = try await api.syncAppStoreTransaction(
                signedTransaction: verification.jwsRepresentation,
                appAccountToken: appAccountToken
            )
            try Task.checkCancellation()
            await transaction.finish()
            return access.snapshot
        case .pending:
            throw AppStorePurchaseError.pending
        case .userCancelled:
            throw AppStorePurchaseError.cancelled
        @unknown default:
            throw AppStorePurchaseError.unknown
        }
    }

    func restore(appAccountToken: UUID) async throws -> AppAccessSnapshot? {
        try await AppStore.sync()
        var firstFailure: Error?
        do { try await recover(appAccountToken: appAccountToken) }
        catch is CancellationError { throw CancellationError() }
        catch { firstFailure = error }
        var latestAccess: AppAccessSnapshot?
        for await result in Transaction.currentEntitlements {
            try Task.checkCancellation()
            let transaction = try verified(result)
            guard AppStoreProductID(rawValue: transaction.productID) != nil else { continue }
            guard transaction.appAccountToken == appAccountToken else { continue }
            do {
                latestAccess = try await api.syncAppStoreTransaction(
                    signedTransaction: result.jwsRepresentation,
                    appAccountToken: appAccountToken
                ).snapshot
                try Task.checkCancellation()
                await transaction.finish()
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

    func recover(appAccountToken: UUID) async throws {
        var firstFailure: Error?
        for await result in Transaction.unfinished {
            try Task.checkCancellation()
            let transaction = try verified(result)
            guard transaction.appAccountToken == appAccountToken,
                  AppStoreProductID(rawValue: transaction.productID) != nil else { continue }
            do { _ = try await synchronize(result, appAccountToken: appAccountToken) }
            catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction): transaction
        case .unverified: throw AppStorePurchaseError.verificationFailed
        }
    }
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
