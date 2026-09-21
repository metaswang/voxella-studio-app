import Foundation

enum AppAccessLicense: String, Codable, Sendable {
    case none
    case trial
    case lifetime
}

enum AppPurchaseSource: String, Codable, Sendable {
    case web
    case appStore = "app_store"
}

struct AppAccessSnapshot: Codable, Equatable, Sendable {
    let license: AppAccessLicense
    let trialEndsAt: Date?
    let subscriptionTier: AccountTier
    let subscriptionEndsAt: Date?
    let purchaseSources: Set<AppPurchaseSource>
    let subscriptionSource: AppPurchaseSource?
    let offlineValidUntil: Date?

    init(
        license: AppAccessLicense = .none,
        trialEndsAt: Date? = nil,
        subscriptionTier: AccountTier = .none,
        subscriptionEndsAt: Date? = nil,
        purchaseSources: Set<AppPurchaseSource> = [],
        subscriptionSource: AppPurchaseSource? = nil,
        offlineValidUntil: Date? = nil
    ) {
        self.license = license
        self.trialEndsAt = trialEndsAt
        self.subscriptionTier = subscriptionTier
        self.subscriptionEndsAt = subscriptionEndsAt
        self.purchaseSources = purchaseSources
        self.subscriptionSource = subscriptionSource
        self.offlineValidUntil = offlineValidUntil
    }

    /// Local-feature entitlement without requiring a server offline lease.
    /// Lifetime (incl. PR2 local credential) and active trial work signed-out.
    /// Paid subscription still needs a valid offline lease when enforced via policy().
    var hasLocalFeatureEntitlement: Bool {
        hasLocalFeatureEntitlement(at: .now)
    }

    func hasLocalFeatureEntitlement(at date: Date) -> Bool {
        if license == .lifetime { return true }
        if license == .trial, let trialEndsAt, trialEndsAt > date { return true }
        return false
    }

    var hasActiveSubscription: Bool {
        hasActiveSubscription(at: .now)
    }

    func hasActiveSubscription(at date: Date) -> Bool {
        subscriptionTier.isPaid && subscriptionEndsAt.map { $0 > date } == true
    }

    func policy(at date: Date = .now) -> AppAccessPolicy {
        // Lifetime: nil offlineValidUntil => local device credential (PR2), always allowed locally.
        // When offlineValidUntil is set (account AppAccessCache lease), honor expiry for refresh UX;
        // AppAccessGate still allows if hasLocalLifetimeCredential.
        if license == .lifetime {
            if let offlineValidUntil {
                return offlineValidUntil > date ? .allowed : .verificationRequired
            }
            return .allowed
        }
        let entitled = hasActiveSubscription(at: date)
            || (license == .trial && trialEndsAt.map { $0 > date } == true)
        guard entitled else { return .expired }
        // Device / provisional trial: endsAt is the hard gate. Offline lease expiry must not
        // block mid-trial local recording (verify is soft / background).
        if license == .trial, hasLocalFeatureEntitlement(at: date) {
            return .allowed
        }
        guard let offlineValidUntil, offlineValidUntil > date else { return .verificationRequired }
        return .allowed
    }

    var canPurchaseCredits: Bool {
        canPurchaseCredits(at: .now)
    }

    func canPurchaseCredits(at date: Date) -> Bool {
        policy(at: date) == .allowed && (license == .lifetime || subscriptionTier.isPaid)
    }

    func trialPresentation(at date: Date = .now) -> TrialPresentation? {
        guard license == .trial, let trialEndsAt else { return nil }
        guard !(subscriptionTier.isPaid && subscriptionEndsAt.map({ $0 > date }) == true)
        else { return nil }

        guard trialEndsAt > date else { return .expired }
        // Show remaining time whenever trial is mid-period — do not hide the clock behind
        // offline verify state (signed-out / unsigned mid-trial must see countdown).
        return .active(TrialPresentation.Active(endsAt: trialEndsAt, now: date))
    }
}

enum TrialPresentation: Equatable, Sendable {
    static let reminderLeadHours: TimeInterval = 72 * 60 * 60

    struct Active: Equatable, Sendable {
        let endsAt: Date
        let remaining: TimeInterval

        init(endsAt: Date, now: Date) {
            self.endsAt = endsAt
            remaining = max(0, endsAt.timeIntervalSince(now))
        }

        var isReminderEligible: Bool { remaining <= TrialPresentation.reminderLeadHours }
        var usesWarningColor: Bool { isReminderEligible }

        var sidebarLabel: String {
            if remaining < 60 * 60 { return "Less than 1 hour left" }
            if remaining < 24 * 60 * 60 { return "\(countLabel(hoursRemaining, unit: "hour")) left" }
            return "\(countLabel(daysRemaining, unit: "day")) left"
        }

        var collapsedLabel: String {
            if remaining < 24 * 60 * 60 { return "<1d" }
            return "\(daysRemaining)d"
        }

        private var hoursRemaining: Int { Int(ceil(remaining / 3_600)) }
        private var daysRemaining: Int { Int(ceil(remaining / 86_400)) }

        private func countLabel(_ count: Int, unit: String) -> String {
            "\(count) \(unit)\(count == 1 ? "" : "s")"
        }
    }

    case active(Active)
    case expired
    case verificationRequired
}

enum AppAccessGate {
    /// Access matrix (PR1):
    /// - Lifetime: local features allowed when license/credential present (no login).
    /// - Active device/server trial: local features allowed signed-out or free signed-in.
    /// - Paid subscription: still requires a signed-in session with a valid lease.
    /// - Purchase checkout / paid cloud / credits: callers keep requiring sign-in separately.
    static func canCreateNewContent(
        enforced: Bool,
        signedIn: Bool,
        access: AppAccessSnapshot,
        hasLocalLifetimeCredential: Bool = false,
        at date: Date = .now
    ) -> Bool {
        (try? requireNewContent(
            enforced: enforced,
            signedIn: signedIn,
            access: access,
            hasLocalLifetimeCredential: hasLocalLifetimeCredential,
            at: date
        )) != nil
    }

    static func hasFeatureAccess(
        hasPaidPlan: Bool,
        access: AppAccessSnapshot,
        hasLocalLifetimeCredential: Bool = false,
        at date: Date = .now
    ) -> Bool {
        hasPaidPlan
            || hasLocalLifetimeCredential
            || access.hasLocalFeatureEntitlement(at: date)
    }

    static func shouldPresentTrialActivationTip(
        enforced: Bool,
        signedIn: Bool,
        hasLocalLifetimeCredential: Bool
    ) -> Bool {
        enforced && signedIn && !hasLocalLifetimeCredential
    }

    static func requireNewContent(
        enforced: Bool,
        signedIn: Bool,
        access: AppAccessSnapshot,
        hasLocalLifetimeCredential: Bool = false,
        at date: Date = .now
    ) throws {
        guard enforced else { return }
        if hasLocalLifetimeCredential || access.license == .lifetime {
            // Local Lifetime credential (PR2 verified JWT) or server lifetime license.
            if access.license == .lifetime, access.policy(at: date) == .verificationRequired, !hasLocalLifetimeCredential {
                throw AppAccessError.verificationRequired
            }
            return
        }
        if access.hasLocalFeatureEntitlement(at: date) {
            // Mid-trial (signed or provisional): allow local recording even if offline verify
            // failed. Policy for trial is endsAt-based; expired trial falls through below.
            switch access.policy(at: date) {
            case .allowed:
                return
            case .verificationRequired:
                // Should not happen for trial after endsAt-based policy; keep as soft deny only
                // for non-trial entitlements that somehow report local entitlement.
                if access.license == .trial { return }
                throw AppAccessError.verificationRequired
            case .expired:
                throw AppAccessError.trialExpired
            }
        }
        if access.hasActiveSubscription(at: date) {
            guard signedIn else { throw AppAccessError.signInRequired }
            switch access.policy(at: date) {
            case .allowed:
                return
            case .verificationRequired:
                throw AppAccessError.verificationRequired
            case .expired:
                throw AppAccessError.verificationRequired
            }
        }
        if access.license == .trial {
            throw AppAccessError.trialExpired
        }
        // No entitlement yet — `prepareNewContentAccess` starts the device trial clock (signed-out OK).
        throw AppAccessError.verificationRequired
    }

    static func label(
        enforced: Bool,
        access: AppAccessSnapshot,
        tier: AccountTier,
        hasLocalLifetimeCredential: Bool = false
    ) -> String {
        guard enforced else { return tier.planLabel }
        if access.license == .lifetime || hasLocalLifetimeCredential { return "Lifetime" }
        if access.subscriptionTier.isPaid, access.subscriptionEndsAt.map({ $0 > .now }) == true {
            return access.subscriptionTier.planLabel
        }
        if access.license == .trial { return "Trial" }
        return "Free"
    }
}

enum AppAccessPolicy: Equatable, Sendable {
    case allowed
    case expired
    case verificationRequired

    func requireNewContent() throws {
        switch self {
        case .allowed: return
        case .expired: throw AppAccessError.trialExpired
        case .verificationRequired: throw AppAccessError.verificationRequired
        }
    }
}

enum CredentialStoreStatus: Equatable, Sendable {
    case ready
    case temporarilyUnavailable
    case configurationError
    case pendingNetworkRestore

    var inlineMessage: String? {
        switch self {
        case .ready:
            nil
        case .temporarilyUnavailable:
            "Secure credential storage is temporarily unavailable. Your projects were left unchanged."
        case .configurationError:
            "This build cannot store credentials. Use a signed VoxStudio build to save sign-in and API keys."
        case .pendingNetworkRestore:
            "Connect to the internet to restore your trial or purchase. Local projects were left unchanged."
        }
    }
}

enum AppAccessError: LocalizedError, Equatable, Sendable {
    case signInRequired
    case trialExpired
    case verificationRequired
    /// Soft / tip: need network to activate (register) device trial — not a login prompt.
    case trialActivationRequired
    case deviceCredentialBindFailed

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to use subscription and cloud features."
        case .trialExpired:
            "Your trial has ended. Choose Lifetime, Starter, or Pro to create new content."
        case .verificationRequired:
            "Connect to the internet to verify your app access."
        case .trialActivationRequired:
            "Connect to the internet to activate your free trial."
        case .deviceCredentialBindFailed:
            "Account upgraded to Lifetime, but this Mac couldn't be bound. You may have reached the device limit. Check your account or contact support."
        }
    }

    var receiptCode: String {
        switch self {
        case .signInRequired: "sign_in_required"
        case .trialExpired: "trial_expired"
        case .verificationRequired: "entitlement_verification_required"
        case .trialActivationRequired: "trial_activation_required"
        case .deviceCredentialBindFailed: "device_credential_bind_failed"
        }
    }

}

struct AppAccessResponse: Decodable, Sendable {
    struct Promotion: Decodable, Sendable {
        let credits: Int
        let endsAt: String
        enum CodingKeys: String, CodingKey {
            case credits
            case endsAt = "ends_at"
        }
    }
    let lifetimePromotion: Promotion?
    let license: AppAccessLicense
    let trialEndsAt: Date?
    let subscriptionTier: AccountTier
    let subscriptionEndsAt: Date?
    let purchaseSources: Set<AppPurchaseSource>
    let subscriptionSource: AppPurchaseSource?
    let offlineValidUntil: Date?

    enum CodingKeys: String, CodingKey {
        case lifetimePromotion = "lifetime_promotion"
        case license
        case trialEndsAt = "trial_ends_at"
        case subscriptionTier = "subscription_tier"
        case subscriptionEndsAt = "subscription_ends_at"
        case purchaseSources = "purchase_sources"
        case subscriptionSource = "subscription_source"
        case offlineValidUntil = "offline_valid_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifetimePromotion = try container.decodeIfPresent(Promotion.self, forKey: .lifetimePromotion)
        license = try container.decodeIfPresent(AppAccessLicense.self, forKey: .license) ?? .none
        trialEndsAt = Self.decodeDate(from: container, key: .trialEndsAt)
        subscriptionTier = try container.decodeIfPresent(AccountTier.self, forKey: .subscriptionTier) ?? .none
        subscriptionEndsAt = Self.decodeDate(from: container, key: .subscriptionEndsAt)
        purchaseSources = try container.decodeIfPresent(Set<AppPurchaseSource>.self, forKey: .purchaseSources) ?? []
        subscriptionSource = try container.decodeIfPresent(AppPurchaseSource.self, forKey: .subscriptionSource)
        offlineValidUntil = try Self.decodeRequiredLease(from: container)
    }

    var snapshot: AppAccessSnapshot {
        AppAccessSnapshot(
            license: license,
            trialEndsAt: trialEndsAt,
            subscriptionTier: subscriptionTier,
            subscriptionEndsAt: subscriptionEndsAt,
            purchaseSources: purchaseSources,
            subscriptionSource: subscriptionSource,
            offlineValidUntil: offlineValidUntil
        )
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func decodeRequiredLease(from container: KeyedDecodingContainer<CodingKeys>) throws -> Date? {
        guard container.contains(.offlineValidUntil), try !container.decodeNil(forKey: .offlineValidUntil) else { return nil }
        guard let date = decodeDate(from: container, key: .offlineValidUntil) else {
            throw DecodingError.dataCorruptedError(forKey: .offlineValidUntil, in: container, debugDescription: "Invalid access expiry")
        }
        return date
    }
}
