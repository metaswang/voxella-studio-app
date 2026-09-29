import AppKit
import Foundation
#if MAC_APP_STORE
import StoreKit
#endif
@preconcurrency import ConvexMobile

struct AccountTier: Hashable, Codable, Sendable {
    let rawValue: String

    static let none = AccountTier(rawValue: "free")

    init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.rawValue = normalized.isEmpty ? "free" : normalized
    }

    init(planCode: String?) {
        self.init(rawValue: planCode ?? Self.none.rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    var isPaid: Bool { rawValue != Self.none.rawValue }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var planLabel: String {
        isPaid ? "\(displayName) plan" : "Free"
    }

    var upgradeLabel: String {
        displayName
    }

    private var displayName: String {
        rawValue
            .split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

struct AccountUser: Codable, Sendable {
    let id: UUID
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? {
        displayName?.split(separator: " ").first.map(String.init)
    }
}

struct AccountPlan: Codable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let planID: String?
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int {
        hasDiscount ? discountedMonthlyPriceUsd! : monthlyPriceUsd
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceUsd else { return false }
        return discounted < monthlyPriceUsd
    }
}

struct AccountResponse: Codable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

private struct OkResponse: Decodable, Sendable {
    let ok: Bool
}

@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

#if !MAC_APP_STORE
    private static let allowedBillingHosts: Set<String> = [
        "checkout.stripe.com",
        "billing.stripe.com",
    ]
#endif

    private static let paidAccessEnabled =
        (Bundle.main.object(forInfoDictionaryKey: "VoxStudioPaidAccessEnabled") as? Bool) ?? false

    private(set) var isLoading: Bool = true
    private(set) var isMisconfigured: Bool = false
    private(set) var account: AccountResponse?
    private(set) var availablePlans: [AvailablePlan] = []
    private(set) var lastError: String?
    private(set) var isSigningIn: Bool = false
    private(set) var isBuyingCredits: Bool = false
    private(set) var authState: AuthState<String> = .loading
    private(set) var cloudBillingBalance: VoxellaBillingBalance?
    private(set) var appAccess = AppAccessSnapshot()
    private(set) var isOfflineAccount = false
    private(set) var lifetimePromotion: AppAccessResponse.Promotion?
    private(set) var credentialStoreStatus: CredentialStoreStatus = .ready
#if !MAC_APP_STORE
    private(set) var isOpeningStripeCheckout = false
    private(set) var anonymousLifetimePhase: AnonymousLifetimePhase = .idle
    @ObservationIgnored private var anonymousPollTask: Task<Void, Never>?
    @ObservationIgnored private var signedInLifetimeCheckoutOwner: UUID?
    @ObservationIgnored private var signedInLifetimePollTask: Task<Void, Never>?
#endif
#if MAC_APP_STORE
    private(set) var isPurchasingAppStoreProduct = false
    private(set) var isLinkingAppStoreLifetime = false
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var transactionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var storeKitInitialRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var storeKitRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var lastAppStoreRecoveryAttempt: Date?

    func purchaseAppStoreProduct(_ id: String) async {
        guard !isPurchasingAppStoreProduct else { return }
        guard let product = AppStoreProductID(rawValue: id) else {
            lastError = AppStorePurchaseError.productUnavailable.localizedDescription
            return
        }
        let generation = sessionGeneration
        let owner = isOfflineAccount ? nil : userID
        isPurchasingAppStoreProduct = true
        lastError = nil
        defer { isPurchasingAppStoreProduct = false }
        do {
            let signedTransaction = try await AppStorePurchaseProvider.shared.purchase(
                product, appAccountToken: owner
            )
            await refreshStoreKitLifetime()
            guard isCurrentSession(generation) else { return }
            if let userID = owner, self.userID == userID {
                do {
                    _ = try await api.syncAppStoreTransaction(
                        signedTransaction: signedTransaction,
                        appAccountToken: userID
                    )
                } catch {
                    guard isCurrentSession(generation) else { return }
                    lastError = L10n.string("Lifetime is active. Account benefits will sync when the connection returns.")
                    return
                }
                await refreshAccountForFeatureAccess()
            }
        } catch {
            await refreshStoreKitLifetime()
            guard isCurrentSession(generation) else { return }
            if (error as? AppStorePurchaseError) != .cancelled { lastError = error.localizedDescription }
        }
    }

    func refreshStoreKitLifetime() async {
        storeKitRefreshGeneration &+= 1
        let generation = storeKitRefreshGeneration
        var facts: [MASLifetimeFact] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == AppStoreProductID.lifetime.rawValue else { continue }
            facts.append(MASLifetimeFact(
                productID: transaction.productID,
                originalID: String(transaction.originalID),
                purchaseDate: transaction.purchaseDate,
                appAccountToken: transaction.appAccountToken,
                revoked: transaction.revocationDate != nil,
                signedTransaction: result.jwsRepresentation
            ))
        }
        guard generation == storeKitRefreshGeneration else { return }
        storeKitLifetimeFacts = facts
        hasLoadedStoreKitLifetime = true
    }

    func linkAnonymousLifetimePurchase() async {
        guard !isLinkingAppStoreLifetime,
              let owner = userID,
              let signedTransaction = anonymousLifetimeLinkJWS else { return }
        let generation = sessionGeneration
        isLinkingAppStoreLifetime = true
        lastError = nil
        defer { isLinkingAppStoreLifetime = false }
        do {
            let access = try await api.linkAppStoreLifetime(signedTransaction: signedTransaction)
            guard isCurrentSession(generation), userID == owner else { return }
            appAccess = access.snapshot
            await refreshAccountForFeatureAccess()
        } catch {
            guard isCurrentSession(generation), userID == owner else { return }
            lastError = error.localizedDescription
        }
    }

    private func recoverAccountBoundAppStorePurchaseIfNeeded(force: Bool = false) {
        guard let owner = userID, isSignedIn,
              !appAccess.purchaseSources.contains(.appStore),
              transactionRecoveryTask == nil else { return }
        if !force, let lastAppStoreRecoveryAttempt,
           Date.now.timeIntervalSince(lastAppStoreRecoveryAttempt) < 60 { return }
        lastAppStoreRecoveryAttempt = .now
        let generation = sessionGeneration
        transactionRecoveryTask = Task { [weak self] in
            defer { self?.transactionRecoveryTask = nil }
            do {
                let access = try await AppStorePurchaseProvider.shared.recover(appAccountToken: owner)
                guard let self, self.isCurrentSession(generation), self.userID == owner else { return }
                if access != nil { await self.refreshAccountForFeatureAccess() }
            } catch {
                guard let self, self.isCurrentSession(generation), self.userID == owner else { return }
                self.lastError = error.localizedDescription
            }
        }
    }
#endif

    var isSignedIn: Bool {
        if isOfflineAccount { return true }
        if case .authenticated = authState { return true }
        return false
    }
    var aiAllowed: Bool { isSignedIn && !isMisconfigured }
    var tier: AccountTier { account?.user.tier ?? .none }
    var isPaid: Bool { tier.isPaid }
    var userID: UUID? { account?.user.id }

#if MAC_APP_STORE
    /// Current verified StoreKit Lifetime transactions. Empty until the first entitlement read.
    private(set) var storeKitLifetimeFacts: [MASLifetimeFact] = []
    private(set) var hasLoadedStoreKitLifetime = false

    var hasLocalLifetimeCredential: Bool {
        MASLifetimePolicy.isUnlocked(
            storeKitLifetimeFacts,
            lifetimeProductID: AppStoreProductID.lifetime.rawValue
        )
    }

    /// Anonymous purchase the signed-in user can explicitly attach. Nil when already stamped or signed out.
    var anonymousLifetimeLinkJWS: String? {
        guard !appAccess.purchaseSources.contains(.appStore) else { return nil }
        return MASLifetimePolicy.linkOffer(
            signedInUserID: isSignedIn && !isOfflineAccount ? userID : nil,
            facts: storeKitLifetimeFacts,
            lifetimeProductID: AppStoreProductID.lifetime.rawValue
        )?.signedTransaction
    }

    private var hasLocalPaidDeviceCredential: Bool { hasLocalLifetimeCredential }
#else
    var hasLocalLifetimeCredential: Bool { LifetimeLocalCredential.isPresent() }
    
    /// Lifetime purchase credential OR license-key device credential.
    private var hasLocalPaidDeviceCredential: Bool {
        hasLocalLifetimeCredential || LicenseKeyLocalCredential.isPresent()
    }
#endif

    /// Apple Lifetime grants MAS local access only while StoreKit has a verified
    /// entitlement. A separate web purchase keeps its existing account path.
    var featureAccessSnapshot: AppAccessSnapshot {
#if MAC_APP_STORE
        return MASLifetimePolicy.localAccess(
            appAccess,
            hasStoreKitLifetime: hasLocalLifetimeCredential
        )
#else
        return appAccess
#endif
    }

    var isAppAccessEnforced: Bool { Self.paidAccessEnabled }
    var canCreateNewContent: Bool {
        AppAccessGate.canCreateNewContent(
            enforced: isAppAccessEnforced,
            signedIn: isSignedIn,
            access: featureAccessSnapshot,
            hasLocalLifetimeCredential: hasLocalPaidDeviceCredential
        )
    }
    /// Trial and Lifetime also satisfy feature-level plan gates; Meet Bot and Calendar use AccountFeature.
    var hasFeatureAccess: Bool {
        AppAccessGate.hasFeatureAccess(
            hasPaidPlan: isPaid,
            access: featureAccessSnapshot,
            hasLocalLifetimeCredential: hasLocalPaidDeviceCredential
        )
    }
    var canUseCloudHighFidelityVoiceRepair: Bool { isSignedIn && isPaid }
    var canPurchaseCredits: Bool { isSignedIn && (!isAppAccessEnforced || appAccess.canPurchaseCredits) }
    var appAccessLabel: String {
        AppAccessGate.label(
            enforced: isAppAccessEnforced,
            access: featureAccessSnapshot,
            tier: tier,
            hasLocalLifetimeCredential: hasLocalPaidDeviceCredential
        )
    }

    /// Trial remaining-time UI. Does NOT require login (device trial survives sign-out).
    var trialPresentation: TrialPresentation? {
        guard isAppAccessEnforced else { return nil }
#if MAC_APP_STORE
        // Do not render a cached device-trial countdown until StoreKit has checked
        // current entitlements. Otherwise Lifetime purchasers briefly see trial UI
        // between app launch and the first entitlement refresh.
        guard hasLoadedStoreKitLifetime, !hasLocalLifetimeCredential else { return nil }
#endif
        return featureAccessSnapshot.trialPresentation()
    }

    var credentialStoreMessage: String? {
        credentialStoreStatus.inlineMessage
    }

    func consumeTrialStartedPresentation() async -> TrialPresentation.Active? {
        await consumeTrialPresentation(
            key: { TrialReminderStore.startedKey(userID: $0, endsAt: $1.endsAt) },
            isEligible: { _ in true }
        )
    }

    func consumeTrialReminderPresentation() async -> TrialPresentation.Active? {
        await consumeTrialPresentation(
            key: { TrialReminderStore.key(userID: $0, endsAt: $1.endsAt) },
            isEligible: \.isReminderEligible
        )
    }

    private func consumeTrialPresentation(
        key: (UUID?, TrialPresentation.Active) -> String,
        isEligible: (TrialPresentation.Active) -> Bool
    ) async -> TrialPresentation.Active? {
        guard case let .active(presentation)? = trialPresentation,
              isEligible(presentation)
        else { return nil }
        guard await trialReminderStore.claim(key: key(userID, presentation)) else { return nil }
        guard case let .active(current)? = trialPresentation,
              current.endsAt == presentation.endsAt,
              isEligible(current)
        else { return nil }
        return current
    }

    var spentCredits: Int { account?.user.spentCreditsThisPeriod ?? 0 }
    var budgetCredits: Int? {
        guard let user = account?.user else { return nil }
        let tierBudget = account?.plan?.monthlyBudgetCredits ?? 0
        return tierBudget + (user.purchasedCredits ?? 0)
    }

    var remainingCredits: Int { max(0, (budgetCredits ?? 0) - spentCredits) }
    var hasCredits: Bool { remainingCredits > 0 }
    var remainingCloudTranscriptionSeconds: Double? {
        cloudBillingBalance?.estimatedSeconds[CloudTranscriptionQuota.uploadUsageType]
    }

    @ObservationIgnored private(set) var convex: ConvexClientWithAuth<String>?
    @ObservationIgnored private var authStateTask: Task<Void, Never>?
    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var buyCreditsTask: Task<Void, Never>?
    @ObservationIgnored private var cloudAccessTask: Task<CloudAccessPreparation, Never>?
    @ObservationIgnored private var cloudAccessGeneration = UUID()
    @ObservationIgnored private let api = VoxellaAPIClient.shared
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var appAccessPreparationTask: Task<Void, Error>?
    @ObservationIgnored private var entitlementRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var entitlementSchedule = AppAccessRefreshSchedule()
    @ObservationIgnored private var entitlementTimerTask: Task<Void, Never>?
    @ObservationIgnored private var accessRequestID = UUID()
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private var didBecomeActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var deviceTrialVerifyAttempt: Date?
#if !MAC_APP_STORE
    @ObservationIgnored private var lifetimeDeviceVerifyAttempt: Date?
    @ObservationIgnored private var licenseKeyDeviceVerifyAttempt: Date?
    @ObservationIgnored private var isVerifyingLicenseKeyDevice = false
#endif
    @ObservationIgnored private let trialReminderStore = TrialReminderStore()

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
#if MAC_APP_STORE
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                guard let self else { continue }
                await self.refreshStoreKitLifetime()
                guard let owner = self.userID else { continue }
                if case .verified(let transaction) = result, transaction.appAccountToken != owner { continue }
                let generation = self.sessionGeneration
                do {
                    _ = try await AppStorePurchaseProvider.shared.synchronize(result, appAccountToken: owner)
                    guard self.isCurrentSession(generation), self.userID == owner else { continue }
                    await self.refreshAccountForFeatureAccess()
                } catch {
                    if self.isCurrentSession(generation), self.userID == owner { self.lastError = error.localizedDescription }
                }
            }
        }
#endif

        if let deploymentURL = BackendConfig.convexDeploymentURL {
            convex = ConvexClientWithAuth(
                deploymentUrl: deploymentURL.absoluteString,
                authProvider: VoxellaConvexAuthProvider()
            )
        } else {
            isMisconfigured = true
            Log.account.warning(
                "convex unavailable host=\(VoxellaAPIConfiguration.baseURL.host ?? "")",
                telemetry: "Convex unavailable",
                data: [
                    "hasConvexURL": false,
                    "voxstudioHost": VoxellaAPIConfiguration.baseURL.host ?? "",
                ]
            )
        }
        Log.account.notice(
            "account configured host=\(VoxellaAPIConfiguration.baseURL.host ?? "") convex=\(!isMisconfigured)",
            telemetry: "Account configured",
            data: [
                "host": VoxellaAPIConfiguration.baseURL.host ?? "",
                "convex": !isMisconfigured,
            ]
        )
        reapplyLocalEntitlementOverlays()
#if MAC_APP_STORE
        storeKitInitialRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshStoreKitLifetime()
        }
#endif
        restoreSession()
#if !MAC_APP_STORE
        Task { await self.renewLicenseKeyLeaseIfNeeded(force: true) }
        Task { await self.resumeAnonymousLifetimeCheckout() }
#endif
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
#if MAC_APP_STORE
                Task { await self?.refreshStoreKitLifetime() }
                self?.recoverAccountBoundAppStorePurchaseIfNeeded()
#else
                Task { await self?.resumeAnonymousLifetimeCheckout() }
                Task { await self?.renewLicenseKeyLeaseIfNeeded(force: true) }
#endif
                self?.refreshEntitlementAfterActivation()
            }
        }
        entitlementTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(AppAccessRefreshSchedule.interval)) }
                catch { return }
                guard let self else { return }
                if NSApplication.shared.isActive { self.refreshEntitlementAfterActivation() }
            }
        }
    }

    private func refreshEntitlementAfterActivation() {
#if !MAC_APP_STORE
        if let owner = signedInLifetimeCheckoutOwner, signedInLifetimePollTask == nil,
           isSignedIn, !isOfflineAccount, userID == owner, !isLoading, !isSigningIn {
            signedInLifetimePollTask = Task { [weak self] in
                guard let self else { return }
                defer { self.signedInLifetimePollTask = nil }
                if let existing = self.entitlementRefreshTask { await existing.value }
                for _ in 0..<20 {
                    guard !Task.isCancelled, self.isSignedIn, !self.isOfflineAccount,
                          self.userID == owner else { return }
                    await self.refreshEntitlementInBackground()
                    if self.featureAccessSnapshot.license == .lifetime {
                        self.signedInLifetimeCheckoutOwner = nil
                        return
                    }
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                }
            }
            return
        }
        guard signedInLifetimePollTask == nil else { return }
#endif
        guard entitlementRefreshTask == nil,
              Self.paidAccessEnabled, isSignedIn, !isLoading, !isSigningIn,
              entitlementSchedule.isDue(at: .now)
        else { return }
        entitlementSchedule.attempted(at: .now)
        entitlementRefreshTask = Task { [weak self] in
            await self?.refreshEntitlementInBackground()
        }
    }

    private func refreshEntitlementInBackground() async {
        defer { entitlementRefreshTask = nil }
        guard Self.paidAccessEnabled, let owner = userID, isSignedIn else { return }
        let generation = sessionGeneration
        let requestID = UUID()
        accessRequestID = requestID
        do {
            let response = try await api.billingPlans()
            guard isCurrentSession(generation), userID == owner, accessRequestID == requestID,
                  let access = response.appAccess?.snapshot else { return }
            appAccess = access
            lifetimePromotion = response.appAccess?.lifetimePromotion
            entitlementSchedule.succeeded(at: .now)
            try await persistAppAccess()
#if !MAC_APP_STORE
            await syncLifetimeDeviceCredentialIfNeeded()
#endif
        } catch {
            guard isCurrentSession(generation), accessRequestID == requestID else { return }
            if AppAccessRefreshSchedule.invalidatesSession(error) { await rejectSession(); return }
            Log.account.warning("Background entitlement refresh unavailable")
        }
    }

    private func restoreSession() {
        authStateTask?.cancel()
        let generation = UUID()
        sessionGeneration = generation
        authStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer {
                if self.sessionGeneration == generation {
                    self.isLoading = false
                    self.authStateTask = nil
                }
            }

#if MAC_APP_STORE
            await self.storeKitInitialRefreshTask?.value
#endif
            _ = await self.restoreOfflineAccess(generation: generation)
            do {
                guard let token = try await VoxellaAuthService.shared.validAccessToken() else {
                    guard self.isCurrentSession(generation) else { return }
                    await self.rejectSession()
                    await self.reconcileDeviceTrialOnLaunch()
                    return
                }
                guard self.isCurrentSession(generation) else { return }
                _ = await self.applyAuthenticatedSession(token: token, generation: generation, allowOfflineRestore: true)
            } catch {
                guard self.isCurrentSession(generation) else { return }
                if AppAccessRefreshSchedule.permitsOfflineFallback(error), await self.restoreOfflineAccess(generation: generation) {
                    await self.reconcileDeviceTrialOnLaunch()
                    return
                }
                await self.rejectSession()
                self.lastError = error.localizedDescription
            }
            await self.reconcileDeviceTrialOnLaunch()
        }
    }

    private func reloadAccount(generation: UUID) async throws {
        let requestID = UUID()
        accessRequestID = requestID
        async let plans = api.billingPlans()
        async let balance = api.billingBalance()
        let profileResponse = try await api.accountProfile()
        let plansResponse: VoxellaUserPlans?
        do {
            plansResponse = try await plans
        } catch {
            if AppAccessRefreshSchedule.invalidatesSession(error) { throw error }
            plansResponse = nil
            Log.account.warning(
                "billing plans refresh failed error=\(error.localizedDescription)",
                telemetry: "Billing plans refresh failed",
                data: ["error": error.localizedDescription]
            )
        }
        let balanceResponse: VoxellaBillingBalance?
        do {
            balanceResponse = try await balance
        } catch {
            balanceResponse = nil
            Log.account.warning(
                "billing balance refresh failed error=\(error.localizedDescription)",
                telemetry: "Billing balance refresh failed",
                data: ["error": error.localizedDescription]
            )
        }

        let currentPlan = plansResponse.flatMap { response in
            response.plans.first { $0.id == response.userPlanID }
        }
        let currentTier = AccountTier(planCode: currentPlan?.planCode)
        let purchasedCredits = Int(
            ((balanceResponse?.topupCredits ?? 0) + (balanceResponse?.grantCredits ?? 0))
                .rounded(.down)
        )
        let budget = (currentPlan?.includedCredits ?? 0) + purchasedCredits
        let available = Int((balanceResponse?.availableCredits ?? 0).rounded(.down))
        let periodEnd = plansResponse?.currentPeriodEnd.flatMap(Self.periodMilliseconds)

        guard isCurrentSession(generation), accessRequestID == requestID else { return }

        if userID != profileResponse.id { appAccess = .init() }
        account = AccountResponse(
            user: AccountUser(
                id: profileResponse.id,
                email: profileResponse.email,
                name: profileResponse.name,
                image: profileResponse.pictureURL,
                tier: currentTier,
                currentPeriodEnd: periodEnd,
                cancelAtPeriodEnd: plansResponse?.statusNote?.localizedCaseInsensitiveContains("cancel") ?? false,
                spentCreditsThisPeriod: max(0, budget - available),
                purchasedCredits: purchasedCredits
            ),
            plan: currentPlan.map {
                AccountPlan(
                    tier: currentTier,
                    monthlyPriceUsd: Self.monthlyPrice(for: $0),
                    monthlyBudgetCredits: $0.includedCredits
                )
            }
        )
        cloudBillingBalance = balanceResponse
        lifetimePromotion = plansResponse?.appAccess?.lifetimePromotion
        isOfflineAccount = false
        if Self.paidAccessEnabled {
            if let reportedAccess = plansResponse?.appAccess?.snapshot {
                appAccess = reportedAccess
                entitlementSchedule.succeeded(at: .now)
                rememberTrialStartHint(from: reportedAccess)
            }
            // Free / unsigned-capable path: fill from device trial when server has no entitlement (PR1).
            reapplyLocalEntitlementOverlays()
        } else {
            appAccess = .init()
        }
        availablePlans = plansResponse?.plans.compactMap { plan in
            let tier = AccountTier(planCode: plan.planCode)
            guard tier.isPaid else { return nil }
            return AvailablePlan(
                tier: tier,
                planID: plan.id,
                monthlyPriceUsd: Self.monthlyPrice(for: plan),
                discountedMonthlyPriceUsd: nil,
                monthlyBudgetCredits: plan.includedCredits
            )
        } ?? []
        lastError = nil
        if Self.paidAccessEnabled, plansResponse?.appAccess != nil {
            do {
                try await persistAppAccess()
            } catch {
                retainEntitlementOnCredentialStoreError(error)
                lastError = L10n.format(
                    "Offline access could not be saved: %@",
                    error.localizedDescription
                )
            }
            guard isCurrentSession(generation) else { return }
            await mergeDeviceTrialOnLoginIfNeeded()
            guard isCurrentSession(generation) else { return }
#if !MAC_APP_STORE
            await syncLifetimeDeviceCredentialIfNeeded()
            guard isCurrentSession(generation) else { return }
#endif
        }
        Telemetry.setUser(id: profileResponse.id.uuidString)
        Analytics.identifyUser(
            id: profileResponse.id.uuidString,
            properties: ["tier": currentTier.rawValue]
        )
    }

    private static func monthlyPrice(for plan: VoxellaBillingPlan) -> Int {
        let price = plan.prices.first { $0.billingInterval == "month" }?.price
            ?? plan.prices.first?.price
            ?? 0
        return Int(price.rounded())
    }

    private static func periodMilliseconds(_ value: String) -> Double? {
        guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.timeIntervalSince1970 * 1_000
    }

    private func clearAccount() {
        accessRequestID = UUID()
        entitlementSchedule = .init()
        if WorkbenchTipCenter.shared.tip?.id == "app-access.(AppAccessError.trialActivationRequired.receiptCode)" {
            WorkbenchTipCenter.shared.hide()
        }
#if MAC_APP_STORE
        transactionRecoveryTask?.cancel()
        transactionRecoveryTask = nil
#endif
        isOfflineAccount = false
        Telemetry.setUser(id: nil)
        Analytics.resetUser()
        buyCreditsTask?.cancel()
        buyCreditsTask = nil
        account = nil
        lifetimePromotion = nil
        cloudBillingBalance = nil
        appAccess = .init()
        availablePlans = []
        isBuyingCredits = false
#if !MAC_APP_STORE
        isOpeningStripeCheckout = false
#endif
        // Device trial survives logout; DMG Lifetime credentials do as well.
        reapplyLocalEntitlementOverlays()
    }

    func signInWithGoogle() async {
        await signIn(provider: "google") {
            try await VoxellaAuthService.shared.signInWithGoogle()
        }
    }

    func signInWithApple() async {
        await signIn(provider: "apple") {
            try await VoxellaAuthService.shared.signInWithApple()
        }
    }

    func signInWithEmail(email: String, password: String) async {
        await signIn(provider: "email") {
            try await VoxellaAuthService.shared.signInWithEmail(email: email, password: password)
        }
    }

    func refreshAccountForFeatureAccess() async {
        await waitForSessionRestore()
        guard isSignedIn else { return }

        let generation = beginSessionOperation()
        isLoading = true
        defer {
            if sessionGeneration == generation {
                isLoading = false
            }
        }
        do {
            try await reloadAccount(generation: generation)
            guard isCurrentSession(generation) else { return }
            HostedCreditAvailability.shared.clearAfterAccountRefresh()
        } catch {
            guard isCurrentSession(generation) else { return }
            if AppAccessRefreshSchedule.invalidatesSession(error) { await rejectSession(); return }
            lastError = error.localizedDescription
        }
    }

    func prepareNewContentAccess() async throws {
        if let task = appAccessPreparationTask {
            do {
                try await task.value
                try Task.checkCancellation()
                try requireNewContentAccess()
                return
            } catch let error as AppAccessError {
                presentAppAccessNotice(for: error)
                throw error
            }
        }
        let task = Task { try await performAppAccessPreparation() }
        appAccessPreparationTask = task
        defer { appAccessPreparationTask = nil }
        do {
            try await task.value
            try Task.checkCancellation()
            try requireNewContentAccess()
        } catch let error as AppAccessError {
            presentAppAccessNotice(for: error)
            throw error
        }
    }

    private func performAppAccessPreparation() async throws {
        guard Self.paidAccessEnabled else { return }
        reapplyLocalEntitlementOverlays()
#if !MAC_APP_STORE
        await renewLifetimeLeaseIfNeeded()
        await renewLicenseKeyLeaseIfNeeded()
#endif
        reapplyLocalEntitlementOverlays()
        if hasLocalPaidDeviceCredential { return }
        if featureAccessSnapshot.policy() == .allowed { return }

        if isLoading, userID == nil {
            _ = await restoreOfflineAccess(generation: sessionGeneration)
            reapplyLocalEntitlementOverlays()
            if featureAccessSnapshot.policy() == .allowed { return }
        }
        await waitForSessionRestore()
        reapplyLocalEntitlementOverlays()
        if featureAccessSnapshot.policy() == .allowed { return }

#if MAC_APP_STORE
        // The Mac App Store build exposes one StoreKit product: Lifetime.
        await refreshAccountForFeatureAccess()
#else
        // DMG: first launch and first gated feature start a device trial without sign-in (PR1.1).
        // Verify only when ≥24h since last success or the token is near expiry.
        // Register failure falls back to a provisional local clock. PR4 account merge; PR2–PR3 Lifetime.
        do {
            try await ensureDeviceTrialStarted()
        } catch AppAccessError.trialExpired {
            lastError = AppAccessError.trialExpired.localizedDescription
            throw AppAccessError.trialExpired
        } catch {
            reapplyLocalEntitlementOverlays()
            if appAccess.policy() == .allowed { return }
            lastError = error.localizedDescription
            throw error as? AppAccessError ?? AppAccessError.verificationRequired
        }
        if appAccess.policy() == .allowed { return }

        // Subscription / paid cloud still need a signed-in session when trial is exhausted.
        if appAccess.hasActiveSubscription, !isSignedIn {
            let preparation = await ensureCloudAccess()
            switch preparation {
            case .ready:
                break
            case .cancelled:
                throw AppAccessError.signInRequired
            case .failed:
                throw AppAccessError.verificationRequired
            }
            await refreshAccountForFeatureAccess()
        }
#endif
        try requireNewContentAccess()
    }

    /// Apply device trial on both distributions; DMG also accepts its local purchase
    /// and license-key credentials. MAS Lifetime comes from StoreKit/account access.
    private func reapplyLocalEntitlementOverlays() {
#if !MAC_APP_STORE
        applyLifetimeCredentialOverlayIfNeeded()
        applyLicenseKeyCredentialOverlayIfNeeded()
#endif
        applyDeviceTrialOverlayIfNeeded()
    }

#if !MAC_APP_STORE
    private func applyLifetimeCredentialOverlayIfNeeded() {
        guard Self.paidAccessEnabled else { return }
        do {
            guard let snapshot = try LifetimeLocalCredential.activeSnapshot() else { return }
            accessRequestID = UUID()
            appAccess = snapshot
            markCredentialStoreReadyIfNeeded()
        } catch {
            retainEntitlementOnCredentialStoreError(error)
        }
    }

    private func applyLicenseKeyCredentialOverlayIfNeeded() {
        guard Self.paidAccessEnabled else { return }
        if hasLocalLifetimeCredential { return }
        guard let snapshot = try? LicenseKeyLocalCredential.activeSnapshot() else { return }
        accessRequestID = UUID()
        appAccess = snapshot
    }


    private func renewLicenseKeyLeaseIfNeeded(force: Bool = false) async {
        guard Self.paidAccessEnabled else { return }
        guard !isVerifyingLicenseKeyDevice else { return }
        guard let record = try? LicenseKeyLocalCredential.load() else { return }
        if !force, !record.refreshIsDue(at: .now, lastAttempt: licenseKeyDeviceVerifyAttempt) {
            return
        }
        isVerifyingLicenseKeyDevice = true
        defer { isVerifyingLicenseKeyDevice = false }
        licenseKeyDeviceVerifyAttempt = .now
        do {
            let response = try await api.verifyLicenseKeyDevice(
                token: record.token,
                fingerprint: record.fingerprint
            )
            try applyLicenseKeyDeviceResponse(response, fingerprint: record.fingerprint)
        } catch let error as VoxellaAPIError {
            if case .http(let code, _) = error, code == 401 || code == 403 {
                try? LicenseKeyLocalCredential.clear()
                if appAccess.license == .lifetime, !hasLocalLifetimeCredential {
                    appAccess = .init()
                }
                reapplyLocalEntitlementOverlays()
            } else {
                Log.account.warning("License key lease renew unavailable")
            }
        } catch {
            Log.account.warning("License key lease renew unavailable")
        }
    }

    private func applyLicenseKeyDeviceResponse(
        _ response: LicenseKeyDeviceAPIResponse,
        fingerprint: String
    ) throws {
        guard !response.token.isEmpty else { throw AppAccessError.verificationRequired }
        let existing = try? LicenseKeyLocalCredential.load()
        _ = try LicenseKeyLocalCredential.store(
            token: response.token,
            fingerprint: fingerprint,
            verifiedAt: .now,
            purchaseSource: response.purchaseSource ?? existing?.envelope.purchaseSource,
            accountLinkStatus: response.accountLinkStatus ?? existing?.envelope.accountLinkStatus
        )
        licenseKeyDeviceVerifyAttempt = .now
        applyLicenseKeyCredentialOverlayIfNeeded()
    }
#endif


    /// Overlay device-local trial onto `appAccess` when no stronger entitlement is present.
    /// Signed mid-trial token (even past offline grace) or provisional local 14d clock.
    /// Expired / missing leaves license at `.none` — do not fabricate a trial clock.
    private func applyDeviceTrialOverlayIfNeeded() {
        guard Self.paidAccessEnabled else { return }
        if hasLocalPaidDeviceCredential { return }
        if appAccess.license == .lifetime { return }
        if appAccess.hasActiveSubscription { return }
        // Only overlay when license is .none (no existing server entitlement).
        if appAccess.license != .none { return }
        do {
            guard let snapshot = try DeviceTrialClock.activeSnapshot() else { return }
            appAccess = snapshot
            markCredentialStoreReadyIfNeeded()
        } catch {
            retainEntitlementOnCredentialStoreError(error)
        }
    }

#if !MAC_APP_STORE
    /// After a DMG Lifetime purchase (or account refresh), issue/store a signed device credential.
    private func syncLifetimeDeviceCredentialIfNeeded() async {
        guard Self.paidAccessEnabled, isSignedIn, let owner = userID else { return }
        guard appAccess.license == .lifetime else { return }
        let fingerprint: String
        do {
            fingerprint = try DeviceFingerprint.current()
        } catch {
            return
        }
        if let existing = try? LifetimeLocalCredential.load(fingerprint: fingerprint),
           existing.userID == owner {
            if existing.refreshIsDue(at: .now, lastAttempt: lifetimeDeviceVerifyAttempt) {
                lifetimeDeviceVerifyAttempt = .now
                do {
                    let response = try await api.verifyLifetimeDevice(fingerprint: fingerprint)
                    try applyLifetimeDeviceResponse(response, fingerprint: fingerprint, userID: owner)
                } catch {
                    // Keep previously verified local credential; try token renew as fallback.
                    await renewLifetimeLeaseIfNeeded(force: true)
                }
            }
            return
        }
        do {
            let response = try await api.issueLifetimeDevice(fingerprint: fingerprint)
            try applyLifetimeDeviceResponse(response, fingerprint: fingerprint, userID: owner)
        } catch {
            Log.account.warning("Lifetime device credential issue unavailable")
        }
    }

    /// PR3: refresh Lifetime lease while signed out using the stored license token.
    private func renewLifetimeLeaseIfNeeded(force: Bool = false) async {
        guard Self.paidAccessEnabled else { return }
        guard let record = try? LifetimeLocalCredential.load() else { return }
        if !force, !record.refreshIsDue(at: .now, lastAttempt: lifetimeDeviceVerifyAttempt) {
            return
        }
        lifetimeDeviceVerifyAttempt = .now
        do {
            let response = try await api.renewLifetimeLease(token: record.token)
            try applyLifetimeDeviceResponse(response, fingerprint: record.fingerprint, userID: record.userID)
        } catch let error as VoxellaAPIError {
            if case .http(let code, _) = error, code == 403 {
                // PR5: refund/revoke — drop local credential and clear in-memory Lifetime.
                try? LifetimeLocalCredential.clear()
                if appAccess.license == .lifetime {
                    appAccess = .init()
                }
                reapplyLocalEntitlementOverlays()
            } else {
                Log.account.warning("Lifetime lease renew unavailable while signed out")
            }
        } catch {
            // Keep previously verified local credential until lease expires.
            Log.account.warning("Lifetime lease renew unavailable while signed out")
        }
    }

    private func applyLifetimeDeviceResponse(
        _ response: LifetimeDeviceAPIResponse,
        fingerprint: String,
        userID: UUID
    ) throws {
        guard !response.token.isEmpty else { throw AppAccessError.verificationRequired }
        _ = try LifetimeLocalCredential.store(
            token: response.token,
            fingerprint: fingerprint,
            userID: userID,
            verifiedAt: .now
        )
        lifetimeDeviceVerifyAttempt = .now
        applyLifetimeCredentialOverlayIfNeeded()
    }
#endif

    /// PR4: on login/account refresh, merge device trial start into the account (earliest wins).
    /// Provisional-only devices must upgrade to a signed token before `/trial`.
    /// Register failure must not POST `/trial` without a token (that reopens 14d from now).
    private func mergeDeviceTrialOnLoginIfNeeded() async {
        guard Self.paidAccessEnabled, isSignedIn else { return }
        // Lifetime / paid subscription: server skips trial merge.
        if appAccess.license == .lifetime || appAccess.hasActiveSubscription { return }

        let provisionalBeforeMerge = try? DeviceTrialClock.loadProvisional()
        let hadSignedBefore = (try? DeviceTrialClock.load()) != nil
        if DeviceTrialLoginMerge.shouldUpgradeProvisionalBeforeMerge(
            hasSignedToken: hadSignedBefore,
            provisional: provisionalBeforeMerge
        ) {
            do {
                // Prefer signed token via register(clientStartedAt: provisional.startedAt).
                try await ensureDeviceTrialStarted()
            } catch {
                Log.account.warning("Provisional device trial upgrade before login merge unavailable")
            }
        }

        let signed = try? DeviceTrialClock.load()
        let provisionalAfterUpgrade = try? DeviceTrialClock.loadProvisional()
        guard DeviceTrialLoginMerge.shouldPostAccountTrialMerge(
            hasSignedToken: signed != nil,
            provisional: provisionalAfterUpgrade
        ) else {
            Log.account.warning("Skipping account trial merge until device trial register succeeds")
            reapplyLocalEntitlementOverlays()
            return
        }

        let payload = DeviceTrialLoginMerge.resolvePayload(
            signedStartedAt: signed?.startedAt,
            signedToken: signed?.envelope.token,
            earliestHint: DeviceTrialClock.earliestClientStartedAtHint()
        )
        do {
            let access = try await api.startAppTrial(
                deviceStartedAt: payload.deviceStartedAt,
                deviceTrialToken: payload.deviceTrialToken
            )
            let serverTrialEndsAt = access.snapshot.trialEndsAt
            appAccess = access.snapshot
            entitlementSchedule.succeeded(at: .now)
            rememberTrialStartHint(from: access.snapshot)
            try? await persistAppAccess()
            if DeviceTrialLoginMerge.shouldClearProvisional(
                serverTrialEndsAt: serverTrialEndsAt,
                provisionalEndsAt: provisionalBeforeMerge?.endsAt
            ) {
                try? DeviceTrialClock.clearProvisional()
            }
            // After merge: if the device token grants more remaining time than the account
            // trial, re-register with the account start so Keychain/sign-out stay aligned.
            if let deviceRecord = try? DeviceTrialClock.load(),
               let serverEndsAt = serverTrialEndsAt,
               deviceRecord.endsAt > serverEndsAt {
                let fingerprint = try? DeviceFingerprint.current()
                guard let fingerprint else {
                    do {
                        try KeychainStore.deleteThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
                    } catch {
                        retainEntitlementOnCredentialStoreError(error)
                    }
                    reapplyLocalEntitlementOverlays()
                    return
                }
                if serverEndsAt <= .now {
                    do {
                        try KeychainStore.deleteThisDeviceOnly(account: DeviceTrialClock.keychainAccount)
                    } catch {
                        retainEntitlementOnCredentialStoreError(error)
                    }
                    reapplyLocalEntitlementOverlays()
                    return
                }
                do {
                    let accountStart = DeviceTrialLoginMerge.inferredStart(fromTrialEndsAt: serverEndsAt)
                    let response = try await api.registerDeviceTrial(
                        fingerprint: fingerprint,
                        clientStartedAt: min(accountStart, deviceRecord.startedAt)
                    )
                    try applyDeviceTrialResponse(response, fingerprint: fingerprint)
                } catch {
                    Log.account.warning("Device trial could not be aligned to account trial end")
                }
            }
            reapplyLocalEntitlementOverlays()
        } catch {
            Log.account.warning("Trial merge on login unavailable")
        }
    }

    private func ensureDeviceTrialStarted() async throws {
        let fingerprint: String
        do {
            fingerprint = try DeviceFingerprint.current()
        } catch {
            reapplyLocalEntitlementOverlays()
            if appAccess.policy() == .allowed { return }
            throw error
        }
        let clientStartedAt = earliestDeviceTrialStartHint()
        let localRecord: DeviceTrialClock.Record?
        do {
            localRecord = try DeviceTrialClock.load(fingerprint: fingerprint)
        } catch {
            if isBlockingCredentialStoreError(error) {
                retainEntitlementOnCredentialStoreError(error)
            }
            localRecord = nil
        }
        if let record = localRecord {
            applyDeviceTrialRecord(record)
            if let clientStartedAt, record.startedAt > clientStartedAt.addingTimeInterval(1) {
                do {
                    try await syncDeviceTrial(
                        fingerprint: fingerprint,
                        preferVerify: false,
                        clientStartedAt: clientStartedAt
                    )
                } catch AppAccessError.trialExpired {
                    throw AppAccessError.trialExpired
                } catch {
                    Log.account.warning("Device trial could not inherit earlier account start")
                }
                return
            }
            switch record.evaluation() {
            case .allowed:
                if record.refreshIsDue(at: .now, lastAttempt: deviceTrialVerifyAttempt) {
                    deviceTrialVerifyAttempt = .now
                    do {
                        try await syncDeviceTrial(
                            fingerprint: fingerprint,
                            preferVerify: true,
                            clientStartedAt: nil
                        )
                    } catch AppAccessError.trialExpired {
                        throw AppAccessError.trialExpired
                    } catch {
                        // Mid-trial signed token: offline / verify failure must still allow recording.
                    }
                }
                return
            case .expired:
                throw AppAccessError.trialExpired
            case .verificationRequired:
                do {
                    try await syncDeviceTrial(
                        fingerprint: fingerprint,
                        preferVerify: true,
                        clientStartedAt: nil
                    )
                } catch AppAccessError.trialExpired {
                    throw AppAccessError.trialExpired
                } catch {
                    applyDeviceTrialRecord(record)
                }
                return
            case .invalid:
                break
            }
        }

        let provisional: DeviceTrialClock.ProvisionalRecord?
        do {
            provisional = try DeviceTrialClock.loadProvisional(fingerprint: fingerprint)
        } catch {
            if isBlockingCredentialStoreError(error) {
                retainEntitlementOnCredentialStoreError(error)
            }
            provisional = nil
        }
        if let provisional {
            switch provisional.evaluation() {
            case .expired:
                throw AppAccessError.trialExpired
            case .invalid:
                do {
                    try DeviceTrialClock.clearProvisional()
                } catch {
                    retainEntitlementOnCredentialStoreError(error)
                }
            case .allowed, .verificationRequired:
                applyProvisionalTrialRecord(provisional)
                guard DeviceTrialBootstrap.shouldRetryNetworkSync(lastAttempt: deviceTrialVerifyAttempt) else {
                    return
                }
                deviceTrialVerifyAttempt = .now
                do {
                    try await syncDeviceTrial(
                        fingerprint: fingerprint,
                        preferVerify: false,
                        clientStartedAt: ([provisional.startedAt] + [clientStartedAt].compactMap { $0 }).min()
                    )
                    return
                } catch AppAccessError.trialExpired {
                    throw AppAccessError.trialExpired
                } catch {
                    Log.account.warning("Provisional device trial register unavailable")
                    return
                }
            }
        }

        guard DeviceTrialBootstrap.shouldRetryNetworkSync(lastAttempt: deviceTrialVerifyAttempt) else {
            activateProvisionalDeviceTrial(fingerprint: fingerprint, startedAt: clientStartedAt)
            return
        }
        deviceTrialVerifyAttempt = .now
        do {
            try await syncDeviceTrial(
                fingerprint: fingerprint,
                preferVerify: DeviceTrialBootstrap.preferVerify(hasSignedToken: false),
                clientStartedAt: clientStartedAt,
                allowRegister: true
            )
            markCredentialStoreReadyIfNeeded()
        } catch AppAccessError.trialExpired {
            throw AppAccessError.trialExpired
        } catch {
            activateProvisionalDeviceTrial(fingerprint: fingerprint, startedAt: clientStartedAt)
            Log.account.warning("Device trial register unavailable; using provisional local clock")
        }
    }

    /// First launch: start a local trial when none exists; only verify an already-signed token.
    private func reconcileDeviceTrialOnLaunch() async {
        guard Self.paidAccessEnabled else { return }
        let hasSignedToken = (try? DeviceTrialClock.load()) != nil
        switch DeviceTrialBootstrap.launchPath(
            paidAccessEnabled: true,
            hasLifetimeCredential: hasLocalLifetimeCredential,
            hasSignedToken: hasSignedToken
        ) {
        case .skip:
            return
        case .verifyOnly:
            await alignDeviceTrialClockWithServer()
        case .startOrUpgrade:
            do {
                try await ensureDeviceTrialStarted()
            } catch AppAccessError.trialExpired {
                lastError = AppAccessError.trialExpired.localizedDescription
                markCredentialStoreReadyIfNeeded()
            } catch {
                Log.account.warning("Device trial launch start unavailable")
                reapplyLocalEntitlementOverlays()
            }
        }
    }

    /// Launch restore for a signed device-trial token. Does not mint a new trial.
    private func alignDeviceTrialClockWithServer() async {
        guard Self.paidAccessEnabled else { return }
        let fingerprint: String
        do {
            fingerprint = try DeviceFingerprint.current()
        } catch {
            return
        }
        do {
            _ = try DeviceTrialClock.load(fingerprint: fingerprint)
        } catch {
            if isBlockingCredentialStoreError(error) {
                retainEntitlementOnCredentialStoreError(error)
                return
            }
        }
        do {
            try await syncDeviceTrial(
                fingerprint: fingerprint,
                preferVerify: true,
                clientStartedAt: earliestDeviceTrialStartHint(),
                allowRegister: false
            )
            markCredentialStoreReadyIfNeeded()
        } catch AppAccessError.trialExpired {
            lastError = AppAccessError.trialExpired.localizedDescription
            markCredentialStoreReadyIfNeeded()
        } catch {
            Log.account.warning("Device trial launch align unavailable")
        }
    }

    private func rememberTrialStartHint(from snapshot: AppAccessSnapshot) {
        guard snapshot.license == .trial, let ends = snapshot.trialEndsAt else { return }
        DeviceTrialClock.rememberClientStartHint(DeviceTrialLoginMerge.inferredStart(fromTrialEndsAt: ends))
    }

    private func earliestDeviceTrialStartHint() -> Date? {
        var candidates: [Date] = []
        if let local = DeviceTrialClock.earliestClientStartedAtHint() {
            candidates.append(local)
        }
        if let signed = try? DeviceTrialClock.load() {
            candidates.append(signed.startedAt)
        }
        if appAccess.license == .trial, let ends = appAccess.trialEndsAt {
            candidates.append(DeviceTrialLoginMerge.inferredStart(fromTrialEndsAt: ends))
        }
        return candidates.min()
    }

    private func applyProvisionalTrialRecord(_ record: DeviceTrialClock.ProvisionalRecord) {
        guard let snapshot = record.snapshot() else { return }
        guard DeviceTrialLoginMerge.shouldReplaceEntitlement(current: appAccess, candidate: snapshot) else {
            return
        }
        accessRequestID = UUID()
        appAccess = snapshot
    }

    private func presentTrialActivationTip() {
        guard AppAccessGate.shouldPresentTrialActivationTip(
            enforced: isAppAccessEnforced,
            signedIn: isSignedIn,
            hasLocalLifetimeCredential: hasLocalPaidDeviceCredential
        ) else { return }

        WorkbenchTipCenter.shared.show(
            AppAccessError.trialActivationRequired.localizedDescription,
            kind: .warning,
            id: "app-access.\(AppAccessError.trialActivationRequired.receiptCode)"
        )
    }

    /// Persist (or overlay) a local 14-day clock when online register is unavailable.
    private func activateProvisionalDeviceTrial(fingerprint: String, startedAt: Date?) {
        let start = DeviceTrialBootstrap.provisionalStart(from: startedAt)
        DeviceTrialClock.rememberClientStartHint(start)
        if let existing = try? DeviceTrialClock.loadProvisional(fingerprint: fingerprint),
           existing.evaluation() == .allowed || existing.evaluation() == .verificationRequired {
            let earliest = min(existing.startedAt, start)
            if earliest < existing.startedAt,
               let updated = try? DeviceTrialClock.storeProvisional(startedAt: earliest, fingerprint: fingerprint) {
                applyProvisionalTrialRecord(updated)
                markCredentialStoreReadyIfNeeded()
                return
            }
            applyProvisionalTrialRecord(existing)
            markCredentialStoreReadyIfNeeded()
            return
        }
        if let record = try? DeviceTrialClock.storeProvisional(startedAt: start, fingerprint: fingerprint) {
            applyProvisionalTrialRecord(record)
        } else {
            applyProvisionalTrialRecord(
                DeviceTrialClock.ProvisionalRecord(startedAt: start, fingerprint: fingerprint)
            )
        }
        markCredentialStoreReadyIfNeeded()
    }

    private func applyDeviceTrialRecord(_ record: DeviceTrialClock.Record) {
        guard let snapshot = record.snapshot() else { return }
        guard DeviceTrialLoginMerge.shouldReplaceEntitlement(current: appAccess, candidate: snapshot) else {
            return
        }
        accessRequestID = UUID()
        appAccess = snapshot
    }

    private func syncDeviceTrial(
        fingerprint: String,
        preferVerify: Bool,
        clientStartedAt: Date?,
        allowRegister: Bool = true
    ) async throws {
        do {
            let response: DeviceTrialAPIResponse
            if preferVerify {
                do {
                    response = try await api.verifyDeviceTrial(fingerprint: fingerprint)
                } catch let error as VoxellaAPIError {
                    if case .http(let code, _) = error, code == 404 {
                        guard allowRegister else { return }
                        response = try await api.registerDeviceTrial(
                            fingerprint: fingerprint,
                            clientStartedAt: clientStartedAt
                        )
                    } else if case .http(let code, _) = error, code == 409 {
                        throw AppAccessError.trialExpired
                    } else {
                        throw error
                    }
                }
            } else {
                response = try await api.registerDeviceTrial(
                    fingerprint: fingerprint,
                    clientStartedAt: clientStartedAt
                )
            }
            try applyDeviceTrialResponse(response, fingerprint: fingerprint)
        } catch let error as AppAccessError {
            throw error
        } catch let error as VoxellaAPIError {
            if case .http(let code, _) = error, code == 409 {
                throw AppAccessError.trialExpired
            }
            // Network / unreachable → caller may keep signed or provisional local trial.
            throw AppAccessError.verificationRequired
        } catch {
            throw AppAccessError.verificationRequired
        }
    }

    private func applyDeviceTrialResponse(_ response: DeviceTrialAPIResponse, fingerprint: String) throws {
        guard !response.token.isEmpty else { throw AppAccessError.verificationRequired }
        let claims = try DeviceTrialLicense.verify(response.token, fingerprint: fingerprint)
        let candidate = AppAccessSnapshot(license: .trial, trialEndsAt: claims.endsAt)
        if !DeviceTrialLoginMerge.shouldReplaceEntitlement(current: appAccess, candidate: candidate) {
            Log.account.warning("Ignoring device trial token that would extend remaining trial time")
            return
        }
        let record = try DeviceTrialClock.store(
            token: response.token,
            fingerprint: fingerprint,
            verifiedAt: .now
        )
        deviceTrialVerifyAttempt = .now
        applyDeviceTrialRecord(record)
        switch record.evaluation() {
        case .allowed:
            return
        case .expired:
            throw AppAccessError.trialExpired
        case .verificationRequired, .invalid:
            throw AppAccessError.verificationRequired
        }
    }

    private func isBlockingCredentialStoreError(_ error: Error) -> Bool {
        guard let error = error as? KeychainStoreError else { return false }
        return error == .temporarilyUnavailable || error == .configurationError
    }

    private func retainEntitlementOnCredentialStoreError(_ error: Error) {
        guard let error = error as? KeychainStoreError else { return }
        switch error {
        case .temporarilyUnavailable:
            credentialStoreStatus = .temporarilyUnavailable
        case .configurationError:
            credentialStoreStatus = .configurationError
        case .corrupted, .invalidValue:
            break
        }
        Log.account.warning("Credential store unavailable error=\(error.localizedDescription)")
    }

    private func markCredentialStoreReadyIfNeeded() {
        if credentialStoreStatus == .temporarilyUnavailable
            || credentialStoreStatus == .configurationError
            || credentialStoreStatus == .pendingNetworkRestore {
            credentialStoreStatus = .ready
        }
    }

    func requireNewContentAccess() throws {
        refreshEntitlementAfterActivation()
        // Keep a valid device trial visible after account/session state changes.
        reapplyLocalEntitlementOverlays()
        do {
            try AppAccessGate.requireNewContent(
                enforced: Self.paidAccessEnabled,
                signedIn: isSignedIn,
                access: featureAccessSnapshot,
                hasLocalLifetimeCredential: hasLocalPaidDeviceCredential
            )
        } catch let error as AppAccessError {
            presentAppAccessNotice(for: error)
            if error == .trialExpired {
                AppAccessWindow.shared.present()
            }
            throw error
        }
    }

    private func presentAppAccessNotice(for error: AppAccessError) {
        WorkbenchTipCenter.shared.show(
            error.localizedDescription,
            kind: .warning,
            id: "app-access.\(error.receiptCode)"
        )
    }

    func ensureCloudAccess() async -> CloudAccessPreparation {
        if let cloudAccessTask {
            return await cloudAccessTask.value
        }
        let accessGeneration = UUID()
        cloudAccessGeneration = accessGeneration
        let task: Task<CloudAccessPreparation, Never> = Task { @MainActor [weak self] in
            guard let self else { return CloudAccessPreparation.failed("VoxStudio could not finish setting up this account.") }
            await self.waitForSessionRestore()
            guard !Task.isCancelled else { return .cancelled }
            if let preparation = await self.preparationIfAlreadyAuthenticated() {
                guard !Task.isCancelled else { return .cancelled }
                return preparation
            }
            guard !Task.isCancelled else { return .cancelled }
            let generation = self.beginSessionOperation()
            self.isSigningIn = true
            self.lastError = nil
            defer {
                if self.sessionGeneration == generation {
                    self.isSigningIn = false
                }
            }
            return await self.performInteractiveCloudAccess(generation: generation)
        }
        cloudAccessTask = task
        let result = await task.value
        if cloudAccessGeneration == accessGeneration {
            cloudAccessTask = nil
        }
        return result
    }

    private func signIn(provider: String, obtainToken: () async throws -> String) async {
        await waitForSessionRestore()
        if isSignedIn, account != nil, (try? await VoxellaAuthService.shared.validAccessToken()) != nil {
            return
        }
        guard !isSigningIn else {
            lastError = "Sign-in is already in progress."
            Log.account.notice(
                "sign in ignored provider=\(provider) reason=in_progress",
                telemetry: "Sign in ignored",
                data: ["provider": provider, "reason": "in_progress"]
            )
            return
        }
        isSigningIn = true
        lastError = nil
        Log.account.notice("sign in requested provider=\(provider)", telemetry: "Sign in requested", data: ["provider": provider])
        let generation = beginSessionOperation()
        defer {
            if sessionGeneration == generation {
                isSigningIn = false
            }
        }
        do {
            let token = try await obtainToken()
            guard isCurrentSession(generation) else { return }
            _ = await applyAuthenticatedSession(token: token, generation: generation)
        } catch {
            guard isCurrentSession(generation) else { return }
            lastError = error.localizedDescription
            Log.account.warning(
                "sign in failed provider=\(provider) error=\(error.localizedDescription)",
                telemetry: "Sign in failed",
                data: ["provider": provider, "error": error.localizedDescription]
            )
        }
    }

    private func waitForSessionRestore() async {
        if let authStateTask {
            await authStateTask.value
        }
    }

    private func preparationIfAlreadyAuthenticated() async -> CloudAccessPreparation? {
        let token: String
        do {
            guard let existing = try await VoxellaAuthService.shared.validAccessToken() else {
                return nil
            }
            token = existing
        } catch VoxellaAuthError.refreshUnavailable {
            let error = VoxellaAuthError.refreshUnavailable
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch {
            Log.account.warning(
                "cloud token restore failed error=\(error.localizedDescription)",
                telemetry: "Cloud token restore failed",
                data: ["error": error.localizedDescription]
            )
            return nil
        }
        if isSignedIn, account != nil {
            return .ready
        }
        return await adoptAuthenticatedSession(token)
    }

    private func performInteractiveCloudAccess(generation: UUID) async -> CloudAccessPreparation {
        guard isCurrentSession(generation) else { return .cancelled }
        do {
            if let token = try await VoxellaAuthService.shared.validAccessToken() {
                return await adoptAuthenticatedSession(token, generation: generation)
            }
        } catch VoxellaAuthError.refreshUnavailable {
            let error = VoxellaAuthError.refreshUnavailable
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch {
            guard isCurrentSession(generation) else { return .cancelled }
            Log.account.warning(
                "cloud token restore failed error=\(error.localizedDescription)",
                telemetry: "Cloud token restore failed",
                data: ["error": error.localizedDescription]
            )
        }
        do {
            guard isCurrentSession(generation) else { return .cancelled }
            let token = try await VoxellaAuthService.shared.ensureSignedIn()
            return await adoptAuthenticatedSession(token, generation: generation)
        } catch VoxellaAuthError.refreshUnavailable {
            let error = VoxellaAuthError.refreshUnavailable
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch VoxellaAuthError.cancelled {
            Log.account.notice("cloud sign-in cancelled", telemetry: "Cloud sign-in cancelled")
            return .cancelled
        } catch {
            guard isCurrentSession(generation) else { return .cancelled }
            lastError = error.localizedDescription
            Log.account.warning(
                "cloud sign-in failed error=\(error.localizedDescription)",
                telemetry: "Cloud sign-in failed",
                data: ["error": error.localizedDescription]
            )
            return .failed(error.localizedDescription)
        }
    }

    private func adoptAuthenticatedSession(
        _ token: String,
        generation: UUID? = nil
    ) async -> CloudAccessPreparation {
        let generation = generation ?? sessionGeneration
        if await applyAuthenticatedSession(token: token, generation: generation) {
            return .ready
        }
        guard isCurrentSession(generation) else {
            if isSignedIn, (try? await VoxellaAuthService.shared.validAccessToken()) != nil {
                return .ready
            }
            return .cancelled
        }
        guard (try? await VoxellaAuthService.shared.validAccessToken()) != nil else {
            if isCurrentSession(generation) {
                authState = .unauthenticated
            }
            return .failed(lastError ?? "VoxStudio could not finish setting up this account.")
        }
        authState = .authenticated(token)
        return .ready
    }

    func cloudTranscriptionQuota(
        durationSeconds: Double,
        includesTranslation: Bool,
        includesVocalRepair: Bool = false,
        sourceUsageType: String = CloudTranscriptionQuota.uploadUsageType
    ) async throws -> CloudTranscriptionQuota {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VoxellaAPIError.http(0, "The media duration is unavailable.")
        }
        var usageTypes = [sourceUsageType]
        if includesTranslation { usageTypes.append(CloudTranscriptionQuota.translationUsageType) }
        if includesVocalRepair { usageTypes.append(CloudTranscriptionQuota.vocalRepairUsageType) }
        let estimate = try await api.usageEstimate(
            durationSeconds: durationSeconds,
            usageTypes: usageTypes
        )
        return CloudTranscriptionQuota(
            durationSeconds: durationSeconds,
            estimatedCredits: estimate.estimatedCredits,
            availableCredits: estimate.availableCredits,
            creditsPerSecond: estimate.creditsPerSecond,
            canAfford: estimate.canAfford
        )
    }

    func cloudDubUsageEstimate(
        language: String?,
        script: String,
        segments: [String]
    ) async throws -> CloudUsageEstimate {
        let estimate = try await api.estimateDub(
            language: language,
            script: script,
            segments: segments
        )
        return CloudUsageEstimate(
            mediaDurationSeconds: estimate.estimatedDurationSec,
            estimatedCostPoints: estimate.estimatedCostPoints,
            remainingCreditsPoints: estimate.quotaRemainingPoints,
            maxDurationSecWithRemainingQuota: estimate.maxDurationSecWithRemainingQuota,
            canAfford: estimate.canAfford
        )
    }

    func updateCloudAvailableCredits(_ credits: Double) {
        guard credits.isFinite, credits >= 0 else { return }
        guard let cloudBillingBalance else { return }
        self.cloudBillingBalance = VoxellaBillingBalance(
            availableCredits: credits,
            subscriptionCredits: cloudBillingBalance.subscriptionCredits,
            topupCredits: cloudBillingBalance.topupCredits,
            grantCredits: cloudBillingBalance.grantCredits,
            estimatedSeconds: cloudBillingBalance.estimatedSeconds
        )
    }

    func signOut() async {
        appAccessPreparationTask?.cancel()
        Log.account.notice("sign out requested", telemetry: "Sign out requested")
        let generation = invalidateSessionOperations()
        isSigningIn = false
        authState = .unauthenticated
        clearAccount()
        do { try await clearOfflineAccess() }
        catch {
            lastError = L10n.format(
                "Offline access could not be removed: %@",
                error.localizedDescription
            )
        }
        // Priority after sign-out: Lifetime device credential first; else active device trial only.
        // Expired / missing trial token stays `.none` (no fabricated countdown).
        reapplyLocalEntitlementOverlays()
        await VoxellaAuthService.shared.signOut()
        guard sessionGeneration == generation else { return }
        await convex?.logout()
    }

    @discardableResult
    private func applyAuthenticatedSession(token: String, generation: UUID, allowOfflineRestore: Bool = false) async -> Bool {
        guard isCurrentSession(generation) else { return false }
        authState = .authenticated(token)
        _ = await convex?.loginFromCache()
        guard isCurrentSession(generation) else { return false }
        do {
            try await reloadAccount(generation: generation)
            guard isCurrentSession(generation) else { return false }
            if let userID { try await VoxellaAuthService.shared.bindAccount(userID, token: token) }
            guard isCurrentSession(generation) else { return false }
#if MAC_APP_STORE
            recoverAccountBoundAppStorePurchaseIfNeeded(force: true)
#endif
            return isCurrentSession(generation)
        } catch {
            guard isCurrentSession(generation) else { return false }
            if allowOfflineRestore, AppAccessRefreshSchedule.permitsOfflineFallback(error), await restoreOfflineAccess(generation: generation) { return true }
            if AppAccessRefreshSchedule.invalidatesSession(error) { await rejectSession(); return false }
            lastError = error.localizedDescription
            Log.account.warning(
                "account refresh failed error=\(error.localizedDescription)",
                telemetry: "Account refresh failed",
                data: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func beginSessionOperation() -> UUID {
        authStateTask?.cancel()
        authStateTask = nil
        isLoading = false
        let generation = UUID()
        sessionGeneration = generation
        return generation
    }

    private func persistAppAccess() async throws {
        guard let account else { return }
        cacheRevision += 1
        try await AppAccessCache.shared.save(account: account, access: appAccess, revision: cacheRevision)
    }

    private func clearOfflineAccess() async throws {
        cacheRevision += 1
        try await AppAccessCache.shared.clear(revision: cacheRevision)
    }

    private func rejectSession() async {
        _ = invalidateSessionOperations()
        authState = .unauthenticated
        clearAccount()
        do { try await clearOfflineAccess() }
        catch {
            lastError = L10n.format(
                "Offline access could not be removed: %@",
                error.localizedDescription
            )
        }
    }

    private func restoreOfflineAccess(generation: UUID) async -> Bool {
        guard Self.paidAccessEnabled else { return false }
        do {
            guard let owner = try await VoxellaAuthService.shared.offlineAccountID(),
                  let entry = try await AppAccessCache.shared.load(), entry.account.user.id == owner,
                  isCurrentSession(generation),
                  userID == nil || userID == entry.account.user.id else { return false }
            account = entry.account
            appAccess = entry.access
            reapplyLocalEntitlementOverlays()
            isOfflineAccount = true
            lastError = nil
            return true
        } catch {
            retainEntitlementOnCredentialStoreError(error)
            lastError = L10n.format(
                "Offline access is unavailable: %@",
                error.localizedDescription
            )
            return false
        }
    }

    private func invalidateSessionOperations() -> UUID {
        authStateTask?.cancel()
        authStateTask = nil
        cloudAccessTask?.cancel()
        cloudAccessTask = nil
        cloudAccessGeneration = UUID()
        isLoading = false
        let generation = UUID()
        sessionGeneration = generation
        return generation
    }

    private func isCurrentSession(_ generation: UUID) -> Bool {
        !Task.isCancelled && sessionGeneration == generation
    }

    func subscribe(tier: AccountTier) async {
        lastError = nil
#if MAC_APP_STORE
        lastError = "Only the Lifetime purchase is available in the Mac App Store version."
#else
        guard userID != nil else {
            lastError = AppAccessError.signInRequired.localizedDescription
            return
        }
        guard !isOpeningStripeCheckout else { return }
        guard tier.isPaid, let planID = availablePlan(for: tier)?.planID else {
            lastError = "The selected plan is unavailable."
            return
        }
        isOpeningStripeCheckout = true
        defer { isOpeningStripeCheckout = false }
        do {
            let result = try await api.createBillingCheckout(planID: planID)
            openInBrowser(result.checkoutURL)
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

#if !MAC_APP_STORE
    /// Activate a license key on this Mac by fingerprint. Login is optional (links account when signed in).
    func redeemLicenseKey(_ key: String) async throws {
        lastError = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let message = L10n.string("Enter a valid license key.")
            lastError = message
            throw VoxellaAPIError.http(400, message)
        }
        if hasLocalLifetimeCredential || appAccess.license == .lifetime {
            let message = L10n.string("This Mac already has Lifetime access.")
            lastError = message
            throw VoxellaAPIError.http(400, message)
        }
        let fingerprint: String
        do {
            fingerprint = try DeviceFingerprint.current()
        } catch {
            lastError = AppAccessError.deviceCredentialBindFailed.localizedDescription
            throw AppAccessError.deviceCredentialBindFailed
        }
        let deviceLabel = Host.current().localizedName
        Log.account.notice("License key activate attempt")
        do {
            let response = try await api.activateLicenseKey(
                key: trimmed,
                fingerprint: fingerprint,
                deviceLabel: deviceLabel
            )
            try applyLicenseKeyDeviceResponse(response, fingerprint: fingerprint)
            entitlementSchedule.succeeded(at: .now)
            try await persistAppAccess()
            if isSignedIn, response.purchaseSource != "stripe_anonymous" {
                // Best-effort: associate key/device with the signed-in account.
                if let token = try? LicenseKeyLocalCredential.load()?.token {
                    do {
                        _ = try await api.linkLicenseKeyAccount(
                            token: token,
                            key: nil,
                            fingerprint: fingerprint
                        )
                        Log.account.notice("License key linked to account")
                    } catch {
                        Log.account.warning("License key account link failed (non-blocking): \(error.localizedDescription)")
                    }
                }
            }
            Log.account.notice("License key activated on this Mac")
        } catch {
            Log.account.warning("License key activate failed (key redacted)")
            lastError = error.localizedDescription
            throw error
        }
    }


    func listLicenseKeyDevices() async throws -> LicenseKeyDevicesListResponse {
        guard let record = try? LicenseKeyLocalCredential.load() else {
            throw VoxellaAPIError.http(
                400,
                L10n.string("License key credential not found. Please activate a license key first.")
            )
        }
        let token = record.token
        let fingerprint = try? DeviceFingerprint.current()
        return try await api.listLicenseKeyDevices(
            token: token,
            licenseKeyID: record.licenseKeyID,
            fingerprint: fingerprint
        )
    }

    func unbindLicenseKeyDevice(fingerprint: String) async throws -> LicenseKeyDevicesListResponse {
        guard let record = try? LicenseKeyLocalCredential.load() else {
            throw VoxellaAPIError.http(400, L10n.string("License key credential not found."))
        }
        let token = record.token
        let result = try await api.unbindLicenseKeyDevice(
            fingerprint: fingerprint,
            token: token,
            licenseKeyID: record.licenseKeyID
        )
        // If we unbound this Mac, clear local credential.
        if let current = try? DeviceFingerprint.current(), current == fingerprint {
            try? LicenseKeyLocalCredential.clear()
            if appAccess.license == .lifetime, !hasLocalLifetimeCredential {
                appAccess = .init()
            }
            reapplyLocalEntitlementOverlays()
        }
        return result
    }
#endif

    func purchaseLifetime() async {
        lastError = nil
#if MAC_APP_STORE
        await purchaseAppStoreProduct(AppStoreProductID.lifetime.rawValue)
#else
        await waitForSessionRestore()
        if let pending = AnonymousLifetimeCheckoutStore.load(),
           !pending.fulfilled || !LicenseKeyLocalCredential.isPresent() {
            await resumeAnonymousLifetimeCheckout(openBrowser: true)
            return
        }
        guard !isOfflineAccount, let owner = userID else {
            await startAnonymousLifetimeCheckout()
            return
        }
        // Signed-in DMG checkout keeps the existing account purchase.
        guard !isOpeningStripeCheckout else { return }
        isOpeningStripeCheckout = true
        defer { isOpeningStripeCheckout = false }
        do {
            let result = try await api.createLifetimeCheckout()
            guard isSignedIn, userID == owner else { return }
            signedInLifetimeCheckoutOwner = owner
            openInBrowser(result.checkoutURL)
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

#if !MAC_APP_STORE
    var canLinkAnonymousLifetime: Bool {
        guard isSignedIn, !isOfflineAccount,
              let record = try? LicenseKeyLocalCredential.load() else { return false }
        return record.envelope.purchaseSource == "stripe_anonymous" && record.envelope.accountLinkStatus != "linked"
    }

    func resumeAnonymousLifetimeCheckout(openBrowser: Bool = false) async {
        guard let pending = AnonymousLifetimeCheckoutStore.load() else {
            if case .unlocked = anonymousLifetimePhase { return }
            anonymousLifetimePhase = .idle
            return
        }
        if let code = pending.recoveryCode {
            if pending.fulfilled && LicenseKeyLocalCredential.isPresent() {
                anonymousLifetimePhase = .unlocked(recoveryCode: code)
                return
            }
            anonymousLifetimePhase = .needsActivation(recoveryCode: code)
        }
        if pending.checkoutID == nil {
            await startAnonymousLifetimeCheckout(reusing: pending)
            return
        }
        if pending.recoveryCode == nil { anonymousLifetimePhase = .awaitingPayment }
        if openBrowser, let checkoutID = pending.checkoutID {
            guard !isOpeningStripeCheckout else { return }
            isOpeningStripeCheckout = true
            defer { isOpeningStripeCheckout = false }
            do {
                // A cached URL is not proof this API owns the payment. Confirm it
                // before reopening, including after an environment switch.
                let response = try await api.anonymousLifetimeStatus(
                    checkoutID: checkoutID,
                    fingerprint: pending.fingerprint,
                    claimCredential: pending.claimCredential
                )
                if response.status == "complete" {
                    await applyAnonymousLifetimeResponse(response, pending: pending)
                    return
                }
                guard response.status == "open", let url = response.checkoutURL else {
                    AnonymousLifetimeCheckoutStore.clear()
                    anonymousLifetimePhase = .idle
                    return
                }
                var refreshed = pending
                refreshed.checkoutURL = url
                refreshed.expiresAt = response.expiresAt
                try AnonymousLifetimeCheckoutStore.save(refreshed)
                openInBrowser(url)
            } catch {
                lastError = error.localizedDescription
                anonymousLifetimePhase = .failed(error.localizedDescription)
                return
            }
        }
        startAnonymousPoll(attempts: 40)
    }

    func checkAnonymousLifetimePayment() async {
        guard AnonymousLifetimeCheckoutStore.load()?.checkoutID != nil else { return }
        anonymousLifetimePhase = .awaitingPayment
        startAnonymousPoll(attempts: 8)
    }

    func cancelAnonymousLifetimeCheckout() async {
        guard let pending = AnonymousLifetimeCheckoutStore.load(), let checkoutID = pending.checkoutID else {
            AnonymousLifetimeCheckoutStore.clear()
            anonymousLifetimePhase = .idle
            return
        }
        anonymousPollTask?.cancel()
        do {
            let response = try await api.cancelAnonymousLifetimeCheckout(
                checkoutID: checkoutID,
                fingerprint: pending.fingerprint,
                claimCredential: pending.claimCredential
            )
            if response.status == "complete" {
                await applyAnonymousLifetimeResponse(response, pending: pending)
                return
            }
            if response.status == "revoked" {
                AnonymousLifetimeCheckoutStore.clear()
                anonymousLifetimePhase = .failed(L10n.string("This Lifetime payment was refunded or disputed."))
                return
            }
            if response.status == "canceled" || response.status == "expired" {
                AnonymousLifetimeCheckoutStore.clear()
                anonymousLifetimePhase = .idle
            } else {
                anonymousLifetimePhase = .waitingForConfirmation
                startAnonymousPoll(attempts: 40)
            }
        } catch {
            lastError = error.localizedDescription
            startAnonymousPoll(attempts: 40)
        }
    }

    func noteAnonymousLifetime(_ message: String) {
        lastError = message
    }

    func acknowledgeAnonymousRecoveryCode() {
        AnonymousLifetimeCheckoutStore.clear()
        if case .unlocked = anonymousLifetimePhase {
            anonymousLifetimePhase = .idle
        }
    }

    func linkAnonymousLifetimeToCurrentAccount() async {
        guard isSignedIn, !isOfflineAccount,
              let token = try? LicenseKeyLocalCredential.load()?.token else { return }
        lastError = L10n.string("Linking this purchase to your account…")
        do {
            var operation = try await api.linkAnonymousLifetime(token: token)
            for _ in 0..<15 {
                if operation.status == "succeeded" {
                    if let record = try? LicenseKeyLocalCredential.load() {
                        _ = try LicenseKeyLocalCredential.store(
                            token: record.token,
                            fingerprint: record.fingerprint,
                            verifiedAt: record.lastVerifiedAt,
                            purchaseSource: "stripe_anonymous",
                            accountLinkStatus: "linked"
                        )
                    }
                    lastError = L10n.string("This purchase is linked to your account.")
                    await refreshAccountForFeatureAccess()
                    return
                }
                if operation.status == "failed" {
                    lastError = operation.errorCode ?? L10n.string("Could not link this purchase to the current account.")
                    return
                }
                try await Task.sleep(for: .seconds(2))
                operation = try await api.billingOperation(operation.operationID)
            }
            lastError = L10n.string("Linking this purchase to your account…")
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startAnonymousLifetimeCheckout(reusing existing: AnonymousLifetimeCheckoutStore.Pending? = nil) async {
        guard !isOpeningStripeCheckout else { return }
        if hasLocalLifetimeCredential || LicenseKeyLocalCredential.isPresent() {
            lastError = L10n.string("This Mac already has Lifetime access.")
            return
        }
        let fingerprint: String
        do {
            fingerprint = try DeviceFingerprint.current()
        } catch {
            lastError = AppAccessError.deviceCredentialBindFailed.localizedDescription
            return
        }
        let claimCredential: String
        if let existing {
            claimCredential = existing.claimCredential
        } else {
            do {
                claimCredential = try AnonymousLifetimeCheckoutStore.makeClaimCredential()
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        var pending = existing ?? AnonymousLifetimeCheckoutStore.Pending(
            idempotencyKey: UUID().uuidString,
            claimCredential: claimCredential,
            fingerprint: fingerprint,
            checkoutID: nil,
            checkoutURL: nil,
            expiresAt: nil,
            recoveryCode: nil,
            fulfilled: false
        )
        guard pending.fingerprint == fingerprint else {
            lastError = L10n.string("This purchase was started on another Mac.")
            return
        }
        do {
            try AnonymousLifetimeCheckoutStore.save(pending)
        } catch {
            lastError = L10n.string("Could not save the purchase on this Mac. Checkout was not opened.")
            return
        }
        isOpeningStripeCheckout = true
        defer { isOpeningStripeCheckout = false }
        do {
            let response = try await api.createAnonymousLifetimeCheckout(
                idempotencyKey: pending.idempotencyKey,
                fingerprint: fingerprint,
                claimCredential: pending.claimCredential,
                deviceLabel: Host.current().localizedName
            )
            pending.checkoutID = response.checkoutID
            pending.checkoutURL = response.checkoutURL
            pending.expiresAt = response.expiresAt
            do {
                try AnonymousLifetimeCheckoutStore.save(pending)
            } catch {
                lastError = L10n.string("Could not save the purchase on this Mac. Checkout was not opened.")
                if let checkoutID = pending.checkoutID {
                    _ = try? await api.cancelAnonymousLifetimeCheckout(
                        checkoutID: checkoutID,
                        fingerprint: fingerprint,
                        claimCredential: pending.claimCredential
                    )
                }
                return
            }
            anonymousLifetimePhase = .awaitingPayment
            if let url = response.checkoutURL {
                openInBrowser(url)
            }
            startAnonymousPoll(attempts: 40)
        } catch {
            lastError = error.localizedDescription
            anonymousLifetimePhase = .failed(error.localizedDescription)
        }
    }

    private func startAnonymousPoll(attempts: Int) {
        anonymousPollTask?.cancel()
        anonymousPollTask = Task { [weak self] in
            await self?.pollAnonymousLifetime(attempts: attempts)
        }
    }

    private func pollAnonymousLifetime(attempts: Int) async {
        for _ in 0..<attempts {
            if Task.isCancelled { return }
            guard let pending = AnonymousLifetimeCheckoutStore.load(), let checkoutID = pending.checkoutID else { return }
            do {
                let response = try await api.anonymousLifetimeStatus(
                    checkoutID: checkoutID,
                    fingerprint: pending.fingerprint,
                    claimCredential: pending.claimCredential
                )
                if Task.isCancelled { return }
                if response.status == "complete" {
                    await applyAnonymousLifetimeResponse(response, pending: pending)
                    return
                }
                if response.status == "canceled" || response.status == "expired" {
                    AnonymousLifetimeCheckoutStore.clear()
                    let message = L10n.string("The checkout expired before payment was confirmed.")
                    lastError = message
                    anonymousLifetimePhase = .failed(message)
                    return
                }
                if response.status == "revoked" {
                    AnonymousLifetimeCheckoutStore.clear()
                    let message = L10n.string("This Lifetime payment was refunded or disputed.")
                    lastError = message
                    anonymousLifetimePhase = .failed(message)
                    return
                }
            } catch {
                Log.account.notice("Anonymous lifetime status check waiting")
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if !Task.isCancelled, let pending = AnonymousLifetimeCheckoutStore.load(), !pending.fulfilled {
            anonymousLifetimePhase = pending.recoveryCode.map { .needsActivation(recoveryCode: $0) }
                ?? .waitingForConfirmation
        }
    }

    private func applyAnonymousLifetimeResponse(
        _ response: AnonymousLifetimeCheckoutResponse,
        pending: AnonymousLifetimeCheckoutStore.Pending
    ) async {
        guard let code = response.recoveryCode, let license = response.license else {
            anonymousLifetimePhase = .waitingForConfirmation
            return
        }
        var saved = pending
        saved.recoveryCode = code
        saved.checkoutID = response.checkoutID
        try? AnonymousLifetimeCheckoutStore.save(saved)
        do {
            try applyLicenseKeyDeviceResponse(license, fingerprint: pending.fingerprint)
            entitlementSchedule.succeeded(at: .now)
            try? await persistAppAccess()
            saved.fulfilled = true
            try? AnonymousLifetimeCheckoutStore.save(saved)
            anonymousLifetimePhase = .unlocked(recoveryCode: code)
        } catch {
            lastError = L10n.string("Could not store the license on this Mac. Save the recovery code, then activate it.")
            anonymousLifetimePhase = .needsActivation(recoveryCode: code)
        }
    }
#endif

    func restorePurchases() async {
#if MAC_APP_STORE
        guard !isPurchasingAppStoreProduct else { return }
        lastError = nil
        let generation = sessionGeneration
        isPurchasingAppStoreProduct = true
        defer { isPurchasingAppStoreProduct = false }
        do {
            try await AppStore.sync()
            await refreshStoreKitLifetime()
            guard isCurrentSession(generation) else { return }
            if let userID, self.userID == userID {
                _ = try await AppStorePurchaseProvider.shared.recover(appAccountToken: userID)
                guard isCurrentSession(generation), self.userID == userID else { return }
                await refreshAccountForFeatureAccess()
            }
        } catch {
            await refreshStoreKitLifetime()
            guard isCurrentSession(generation) else { return }
            lastError = error.localizedDescription
        }
#endif
    }

    func buyCredits(dollars: Int) {
        guard canPurchaseCredits else {
            lastError = "Choose Lifetime, Starter, or Pro before buying credits."
            return
        }
        guard (TopOffLimits.minDollars...TopOffLimits.maxDollars).contains(dollars) else {
            lastError = L10n.format(
                "Amount must be $%@–$%@.",
                TopOffLimits.minDollars,
                TopOffLimits.maxDollars
            )
            return
        }
        if isBuyingCredits { return }
        lastError = nil
        isBuyingCredits = true
        buyCreditsTask = Task { @MainActor [weak self] in
            defer {
                self?.isBuyingCredits = false
                self?.buyCreditsTask = nil
            }
            do {
                guard let self else { return }
#if MAC_APP_STORE
                self.lastError = "Credit purchases are not available in the Mac App Store version."
#else
                let result = try await self.api.createBillingCheckout(topupAmountUSD: Double(dollars))
                self.openInBrowser(result.checkoutURL)
#endif
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func sendFeedback(
        message: String,
        email: String?,
        mayContact: Bool,
        screenshotPngBase64: String?,
        appVersion: String,
        osVersion: String
    ) async throws {
        guard let convex else {
            throw NSError(
                domain: "Palmier.Feedback",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Backend not configured."]
            )
        }
        var args: [String: ConvexEncodable?] = [
            "message": message,
            "mayContact": mayContact,
            "appVersion": appVersion,
            "osVersion": osVersion,
        ]
        if let email { args["email"] = email }
        if let screenshotPngBase64 { args["screenshotPngBase64"] = screenshotPngBase64 }
        let _: OkResponse = try await convex.action("feedback:send", with: args)
    }

    func manageSubscription() async {
        lastError = nil
        if appAccess.subscriptionSource == .appStore {
            guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
            if !NSWorkspace.shared.open(url) { lastError = "Could not open Apple subscription settings." }
            return
        }
#if MAC_APP_STORE
        lastError = "This subscription is managed outside the App Store."
#else
        do {
            let result = try await api.createBillingPortal()
            openInBrowser(result.url)
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

#if !MAC_APP_STORE
    private func openInBrowser(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host,
              Self.allowedBillingHosts.contains(host)
        else {
            lastError = "Refused to open untrusted URL."
            return
        }
        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
    }
#endif
}

// MARK: - Display helpers

extension AccountService {
    var displayPrimaryText: String {
        if !isSignedIn { return L10n.string("Signed out") }
        let user = account?.user
        return user?.displayName ?? user?.email ?? L10n.string("Signed in")
    }

    var displaySecondaryText: String? {
        guard isSignedIn else { return nil }
        let user = account?.user
        return user?.displayName != nil ? user?.email : nil
    }

    var displayInitial: String {
        guard isSignedIn else { return "" }
        let user = account?.user
        let source = user?.displayName ?? user?.email ?? ""
        return source.first.map { String($0).uppercased() } ?? ""
    }

    func availablePlan(for tier: AccountTier) -> AvailablePlan? {
        availablePlans.first { $0.tier == tier }
    }

    var localizedAppAccessLabel: String {
        guard isAppAccessEnforced else { return tier.localizedPlanLabel }
        if featureAccessSnapshot.license == .lifetime || hasLocalLifetimeCredential {
            return L10n.string("Lifetime")
        }
        if featureAccessSnapshot.subscriptionTier.isPaid,
           featureAccessSnapshot.subscriptionEndsAt.map({ $0 > .now }) == true {
            return featureAccessSnapshot.subscriptionTier.localizedPlanLabel
        }
        if featureAccessSnapshot.license == .trial { return L10n.string("Trial") }
        return L10n.string("Free")
    }
}

extension AccountTier {
    @MainActor
    var localizedUpgradeLabel: String {
        L10n.string(key: upgradeLabel)
    }

    @MainActor
    var localizedPlanLabel: String {
        isPaid ? L10n.format("%@ plan", localizedUpgradeLabel) : L10n.string("Free")
    }
}
