import AppKit
import Foundation
@preconcurrency import ConvexMobile

struct AccountTier: Hashable, Decodable, Sendable {
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

struct AccountUser: Decodable, Sendable {
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

struct AccountPlan: Decodable, Sendable {
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

struct AccountResponse: Decodable, Sendable {
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

    private static let allowedBillingHosts: Set<String> = [
        "checkout.stripe.com",
        "billing.stripe.com",
    ]

    private(set) var isLoading: Bool = true
    private(set) var isMisconfigured: Bool = false
    private(set) var account: AccountResponse?
    private(set) var availablePlans: [AvailablePlan] = []
    private(set) var lastError: String?
    private(set) var isSigningIn: Bool = false
    private(set) var isBuyingCredits: Bool = false
    private(set) var authState: AuthState<String> = .loading
    private(set) var cloudBillingBalance: VoxellaBillingBalance?

    var isSignedIn: Bool {
        if case .authenticated = authState { return true }
        return false
    }
    var aiAllowed: Bool { isSignedIn && !isMisconfigured }
    var tier: AccountTier { account?.user.tier ?? .none }
    var isPaid: Bool { tier.isPaid }

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

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true

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
        restoreSession()
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

            do {
                guard let token = try await VoxellaAuthService.shared.validAccessToken() else {
                    guard self.isCurrentSession(generation) else { return }
                    self.authState = .unauthenticated
                    self.clearAccount()
                    return
                }
                guard self.isCurrentSession(generation) else { return }
                _ = await self.applyAuthenticatedSession(token: token, generation: generation)
            } catch {
                guard self.isCurrentSession(generation) else { return }
                self.authState = .unauthenticated
                self.clearAccount()
                self.lastError = error.localizedDescription
            }
        }
    }

    private func reloadAccount(generation: UUID) async throws {
        async let plans = api.billingPlans()
        async let balance = api.billingBalance()
        let profileResponse = try await api.accountProfile()
        let plansResponse: VoxellaUserPlans?
        do {
            plansResponse = try await plans
        } catch {
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

        guard isCurrentSession(generation) else { return }

        account = AccountResponse(
            user: AccountUser(
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
        Telemetry.setUser(id: nil)
        Analytics.resetUser()
        buyCreditsTask?.cancel()
        buyCreditsTask = nil
        account = nil
        cloudBillingBalance = nil
        availablePlans = []
        isBuyingCredits = false
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

    func ensureCloudAccess() async -> CloudAccessPreparation {
        if let cloudAccessTask {
            return await cloudAccessTask.value
        }
        let accessGeneration = UUID()
        cloudAccessGeneration = accessGeneration
        let task: Task<CloudAccessPreparation, Never> = Task { @MainActor [weak self] in
            guard let self else { return CloudAccessPreparation.failed("VoxStudio could not finish setting up this account.") }
            await self.waitForSessionRestore()
            if let preparation = await self.preparationIfAlreadyAuthenticated() {
                return preparation
            }
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
        includesTranslation: Bool
    ) async throws -> CloudTranscriptionQuota {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VoxellaAPIError.http(0, "The media duration is unavailable.")
        }
        let usageTypes = includesTranslation
            ? [CloudTranscriptionQuota.uploadUsageType, CloudTranscriptionQuota.translationUsageType]
            : [CloudTranscriptionQuota.uploadUsageType]
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
        Log.account.notice("sign out requested", telemetry: "Sign out requested")
        let generation = invalidateSessionOperations()
        isSigningIn = false
        authState = .unauthenticated
        clearAccount()
        await VoxellaAuthService.shared.signOut()
        guard sessionGeneration == generation else { return }
        await convex?.logout()
    }

    @discardableResult
    private func applyAuthenticatedSession(token: String, generation: UUID) async -> Bool {
        guard isCurrentSession(generation) else { return false }
        authState = .authenticated(token)
        _ = await convex?.loginFromCache()
        guard isCurrentSession(generation) else { return false }
        do {
            try await reloadAccount(generation: generation)
            return isCurrentSession(generation)
        } catch {
            guard isCurrentSession(generation) else { return false }
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
    }

    func buyCredits(dollars: Int) {
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
                let result = try await self.api.createBillingCheckout(topupAmountUSD: Double(dollars))
                self.openInBrowser(result.checkoutURL)
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
        do {
            let result = try await api.createBillingPortal()
            openInBrowser(result.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

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
