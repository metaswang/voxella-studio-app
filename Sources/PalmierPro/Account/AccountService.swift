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
#if MAC_APP_STORE
    private(set) var isPurchasingAppStoreProduct = false
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var transactionRecoveryTask: Task<Void, Never>?

    func purchaseAppStoreProduct(_ id: String) async {
        guard !isPurchasingAppStoreProduct else { return }
        guard let product = AppStoreProductID(rawValue: id), let userID else {
            lastError = AppAccessError.signInRequired.localizedDescription
            return
        }
        if [.credits5, .credits10, .credits20, .credits50].contains(product), !canPurchaseCredits {
            lastError = "Choose Lifetime, Starter, or Pro before buying credits."
            return
        }
        let generation = sessionGeneration
        isPurchasingAppStoreProduct = true
        lastError = nil
        defer { isPurchasingAppStoreProduct = false }
        do {
            _ = try await AppStorePurchaseProvider.shared.purchase(product, appAccountToken: userID)
            guard isCurrentSession(generation), self.userID == userID else { return }
            await refreshAccountForFeatureAccess()
        } catch {
            guard isCurrentSession(generation) else { return }
            if (error as? AppStorePurchaseError) != .cancelled { lastError = error.localizedDescription }
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
    var isAppAccessEnforced: Bool { Self.paidAccessEnabled }
    var canCreateNewContent: Bool {
        AppAccessGate.canCreateNewContent(
            enforced: isAppAccessEnforced,
            signedIn: isSignedIn,
            access: appAccess,
            hasLocalLifetimeCredential: LifetimeLocalCredential.isPresent()
        )
    }
    var canPurchaseCredits: Bool { isSignedIn && (!isAppAccessEnforced || appAccess.canPurchaseCredits) }
    var appAccessLabel: String {
        AppAccessGate.label(
            enforced: isAppAccessEnforced,
            access: appAccess,
            tier: tier,
            hasLocalLifetimeCredential: LifetimeLocalCredential.isPresent()
        )
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
    @ObservationIgnored private var lifetimeDeviceVerifyAttempt: Date?

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
#if MAC_APP_STORE
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                guard let self, let owner = self.userID else { continue }
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
        applyDeviceTrialOverlayIfNeeded()
        restoreSession()
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
            await syncLifetimeDeviceCredentialIfNeeded()
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

            _ = await self.restoreOfflineAccess(generation: generation)
            do {
                guard let token = try await VoxellaAuthService.shared.validAccessToken() else {
                    guard self.isCurrentSession(generation) else { return }
                    await self.rejectSession()
                    return
                }
                guard self.isCurrentSession(generation) else { return }
                _ = await self.applyAuthenticatedSession(token: token, generation: generation, allowOfflineRestore: true)
            } catch {
                guard self.isCurrentSession(generation) else { return }
                if AppAccessRefreshSchedule.permitsOfflineFallback(error), await self.restoreOfflineAccess(generation: generation) { return }
                await self.rejectSession()
                self.lastError = error.localizedDescription
            }
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
            }
            // Free / unsigned-capable path: fill from device trial when server has no entitlement (PR1).
            applyLifetimeCredentialOverlayIfNeeded()
            applyDeviceTrialOverlayIfNeeded()
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
            do { try await persistAppAccess() }
            catch { lastError = "Offline access could not be saved: \(error.localizedDescription)" }
            guard isCurrentSession(generation) else { return }
            await syncLifetimeDeviceCredentialIfNeeded()
            guard isCurrentSession(generation) else { return }
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
        // Device trial + Lifetime device credential survive logout / account clear (PR1 / PR2).
        applyLifetimeCredentialOverlayIfNeeded()
        applyDeviceTrialOverlayIfNeeded()
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
        applyLifetimeCredentialOverlayIfNeeded()
        await renewLifetimeLeaseIfNeeded()
        applyLifetimeCredentialOverlayIfNeeded()
        applyDeviceTrialOverlayIfNeeded()
        if LifetimeLocalCredential.isPresent() { return }
        if appAccess.policy() == .allowed { return }

        if isLoading, userID == nil {
            _ = await restoreOfflineAccess(generation: sessionGeneration)
            applyDeviceTrialOverlayIfNeeded()
            if appAccess.policy() == .allowed { return }
        }
        await waitForSessionRestore()
        applyDeviceTrialOverlayIfNeeded()
        if appAccess.policy() == .allowed { return }

#if MAC_APP_STORE
        // MAS trial remains StoreKit + account-bound.
        if !isSignedIn {
            let preparation = await ensureCloudAccess()
            switch preparation {
            case .ready:
                break
            case .cancelled:
                throw AppAccessError.signInRequired
            case .failed:
                throw AppAccessError.verificationRequired
            }
        }
        await refreshAccountForFeatureAccess()
        if appAccess.license == .none, !tier.isPaid {
            let generation = sessionGeneration
            let owner = userID
            do {
                guard let userID else { throw AppAccessError.signInRequired }
                guard let access = try await AppStorePurchaseProvider.shared.purchase(.trial, appAccountToken: userID) else {
                    throw AppAccessError.verificationRequired
                }
                guard isCurrentSession(generation), self.userID == owner else { throw CancellationError() }
                accessRequestID = UUID()
                appAccess = access
                entitlementSchedule.succeeded(at: .now)
                try await persistAppAccess()
                try Task.checkCancellation()
            } catch {
                lastError = error.localizedDescription
                throw (error as? AppAccessError) ?? AppAccessError.verificationRequired
            }
        }
#else
        // DMG: first gated feature registers a signed device trial without sign-in (PR1.1).
        // Verify only when ≥24h since last success or the token is near expiry — not on launch
        // and not on every prepareNewContentAccess. PR4 account merge; PR2–PR3 Lifetime.
        do {
            try await ensureDeviceTrialStarted()
        } catch {
            lastError = error.localizedDescription
            throw (error as? AppAccessError) ?? AppAccessError.verificationRequired
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

    /// Overlay verified Lifetime device credential (independent Keychain; survives logout).
    private func applyLifetimeCredentialOverlayIfNeeded() {
        guard Self.paidAccessEnabled else { return }
        guard let snapshot = try? LifetimeLocalCredential.activeSnapshot() else { return }
        accessRequestID = UUID()
        appAccess = snapshot
    }

    /// Overlay device-local trial onto `appAccess` when no stronger entitlement is present.
    private func applyDeviceTrialOverlayIfNeeded() {
        guard Self.paidAccessEnabled else { return }
        if LifetimeLocalCredential.isPresent() { return }
        if appAccess.license == .lifetime { return }
        if appAccess.hasActiveSubscription { return }
        // Keep an existing server/device trial snapshot; only fill `.none`.
        if appAccess.hasLocalFeatureEntitlement { return }
        guard let snapshot = try? DeviceTrialClock.currentSnapshot() else { return }
        appAccess = snapshot
    }

    /// After Lifetime purchase (or account refresh), issue/store signed device credential.
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

    private func ensureDeviceTrialStarted() async throws {
        let fingerprint = try DeviceFingerprint.current()
        if let record = try? DeviceTrialClock.load(fingerprint: fingerprint) {
            applyDeviceTrialRecord(record)
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
                        // Still inside 7d grace: keep the local signed token.
                    }
                }
                return
            case .expired:
                throw AppAccessError.trialExpired
            case .verificationRequired:
                try await syncDeviceTrial(
                    fingerprint: fingerprint,
                    preferVerify: true,
                    clientStartedAt: nil
                )
                return
            case .invalid:
                break
            }
        }
        // First gated feature (or wiped Keychain): register once. Not on launch.
        try await syncDeviceTrial(
            fingerprint: fingerprint,
            preferVerify: false,
            clientStartedAt: DeviceTrialClock.legacyStartedAtHint()
        )
    }

    private func applyDeviceTrialRecord(_ record: DeviceTrialClock.Record) {
        accessRequestID = UUID()
        if let snapshot = record.snapshot() {
            appAccess = snapshot
        }
    }

    private func syncDeviceTrial(
        fingerprint: String,
        preferVerify: Bool,
        clientStartedAt: Date?
    ) async throws {
        do {
            let response: DeviceTrialAPIResponse
            if preferVerify {
                do {
                    response = try await api.verifyDeviceTrial(fingerprint: fingerprint)
                } catch let error as VoxellaAPIError {
                    if case .http(let code, _) = error, code == 404 {
                        response = try await api.registerDeviceTrial(
                            fingerprint: fingerprint,
                            clientStartedAt: clientStartedAt
                        )
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
        } catch {
            throw AppAccessError.verificationRequired
        }
    }

    private func applyDeviceTrialResponse(_ response: DeviceTrialAPIResponse, fingerprint: String) throws {
        guard !response.token.isEmpty else { throw AppAccessError.verificationRequired }
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

    func requireNewContentAccess() throws {
        refreshEntitlementAfterActivation()
        do {
            try AppAccessGate.requireNewContent(
                enforced: Self.paidAccessEnabled,
                signedIn: isSignedIn,
                access: appAccess,
                hasLocalLifetimeCredential: LifetimeLocalCredential.isPresent()
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
        catch { lastError = "Offline access could not be removed: \(error.localizedDescription)" }
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
            if let owner = userID {
                transactionRecoveryTask?.cancel()
                transactionRecoveryTask = Task { [weak self] in
                    do {
                        try await AppStorePurchaseProvider.shared.recover(appAccountToken: owner)
                        guard !Task.isCancelled, self?.userID == owner else { return }
                        await self?.refreshAccountForFeatureAccess()
                    } catch {
                        if !Task.isCancelled, self?.userID == owner { self?.lastError = error.localizedDescription }
                    }
                }
            }
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
        catch { lastError = "Offline access could not be removed: \(error.localizedDescription)" }
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
            applyDeviceTrialOverlayIfNeeded()
            isOfflineAccount = true
            lastError = nil
            return true
        } catch {
            lastError = "Offline access is unavailable: \(error.localizedDescription)"
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
        guard let userID else {
            lastError = AppAccessError.signInRequired.localizedDescription
            return
        }
        let productID: AppStoreProductID
        switch tier.rawValue {
        case "starter": productID = .starter
        case "pro": productID = .pro
        default:
            lastError = "The selected plan is unavailable."
            return
        }
        await purchaseAppStoreProduct(productID.rawValue)
#else
        guard tier.isPaid, let planID = availablePlan(for: tier)?.planID else {
            lastError = "The selected plan is unavailable."
            return
        }
        do {
            let result = try await api.createBillingCheckout(planID: planID)
            openInBrowser(result.checkoutURL)
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

    func purchaseLifetime() async {
        lastError = nil
        // Lifetime checkout binds the account and issues a device credential (PR2) — login required.
        guard userID != nil else {
            lastError = AppAccessError.signInRequired.localizedDescription
            return
        }
#if MAC_APP_STORE
        await purchaseAppStoreProduct(AppStoreProductID.lifetime.rawValue)
#else
        do {
            let result = try await api.createLifetimeCheckout()
            openInBrowser(result.checkoutURL)
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

    func restorePurchases() async {
#if MAC_APP_STORE
        guard !isPurchasingAppStoreProduct else { return }
        lastError = nil
        guard let userID else {
            lastError = AppAccessError.signInRequired.localizedDescription
            return
        }
        let generation = sessionGeneration
        isPurchasingAppStoreProduct = true
        defer { isPurchasingAppStoreProduct = false }
        do {
            _ = try await AppStorePurchaseProvider.shared.restore(appAccountToken: userID)
            guard isCurrentSession(generation), self.userID == userID else { return }
            await refreshAccountForFeatureAccess()
        } catch {
            guard isCurrentSession(generation), self.userID == userID else { return }
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
            lastError = "Amount must be $\(TopOffLimits.minDollars)–$\(TopOffLimits.maxDollars)."
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
                guard let userID = self.userID else {
                    self.lastError = AppAccessError.signInRequired.localizedDescription
                    return
                }
                let productID: AppStoreProductID
                switch dollars {
                case 5: productID = .credits5
                case 10: productID = .credits10
                case 20: productID = .credits20
                case 50: productID = .credits50
                default:
                    self.lastError = "Choose a $5, $10, $20, or $50 credit pack."
                    return
                }
                await self.purchaseAppStoreProduct(productID.rawValue)
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
        if !isSignedIn { return "Signed out" }
        let user = account?.user
        return user?.displayName ?? user?.email ?? "Signed in"
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
}
