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

    func policy(at date: Date = .now) -> AppAccessPolicy {
        let entitled = license == .lifetime
            || (subscriptionTier.isPaid && subscriptionEndsAt.map { $0 > date } == true)
            || (license == .trial && trialEndsAt.map { $0 > date } == true)
        guard entitled else { return .expired }
        guard let offlineValidUntil, offlineValidUntil > date else { return .verificationRequired }
        return .allowed
    }

    var canPurchaseCredits: Bool {
        canPurchaseCredits(at: .now)
    }

    func canPurchaseCredits(at date: Date) -> Bool {
        policy(at: date) == .allowed && (license == .lifetime || subscriptionTier.isPaid)
    }
}

enum AppAccessGate {
    static func canCreateNewContent(
        enforced: Bool,
        signedIn: Bool,
        access: AppAccessSnapshot,
        at date: Date = .now
    ) -> Bool {
        !enforced || (signedIn && access.policy(at: date) == .allowed)
    }

    static func requireNewContent(
        enforced: Bool,
        signedIn: Bool,
        access: AppAccessSnapshot,
        at date: Date = .now
    ) throws {
        guard enforced else { return }
        guard signedIn else { throw AppAccessError.signInRequired }
        try access.policy(at: date).requireNewContent()
    }

    static func label(enforced: Bool, access: AppAccessSnapshot, tier: AccountTier) -> String {
        guard enforced else { return tier.planLabel }
        if access.license == .lifetime { return "Lifetime" }
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

enum AppAccessError: LocalizedError, Equatable, Sendable {
    case signInRequired
    case trialExpired
    case verificationRequired

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to start your 14-day trial."
        case .trialExpired:
            "Your trial has ended. Choose Lifetime, Starter, or Pro to create new content."
        case .verificationRequired:
            "Connect to the internet to verify your app access."
        }
    }

    var receiptCode: String {
        switch self {
        case .signInRequired: "sign_in_required"
        case .trialExpired: "trial_expired"
        case .verificationRequired: "entitlement_verification_required"
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
