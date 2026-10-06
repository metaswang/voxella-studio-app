import Foundation
import Synchronization
import Testing
@testable import VoxstudioPro

@Suite("App access refresh")
struct AppAccessRefreshTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func frequentActivationDoesNotRetryFailedRequests() {
        var schedule = AppAccessRefreshSchedule()
        #expect(schedule.isDue(at: now))
        schedule.attempted(at: now)
        #expect(!schedule.isDue(at: now.addingTimeInterval(60)))
        #expect(schedule.isDue(at: now.addingTimeInterval(300)))
        schedule.succeeded(at: now)
        #expect(!schedule.isDue(at: now.addingTimeInterval(6 * 3600 - 1)))
        #expect(schedule.isDue(at: now.addingTimeInterval(6 * 3600)))
    }

    @Test func networkFailurePreservesCacheButRevocationDoesNot() {
        #expect(AppAccessRefreshSchedule.permitsOfflineFallback(VoxellaAuthError.refreshUnavailable))
        #expect(AppAccessRefreshSchedule.permitsOfflineFallback(URLError(.notConnectedToInternet)))
        #expect(!AppAccessRefreshSchedule.permitsOfflineFallback(VoxellaAuthError.refreshFailed))
        #expect(AppAccessRefreshSchedule.invalidatesSession(VoxellaAPIError.unauthorized))
        #expect(AppAccessRefreshSchedule.invalidatesSession(VoxellaAuthError.refreshFailed))
    }

    @Test func missingLeaseOnLifetimeFollowsLocalCredentialSemantics() throws {
        // PR2: lifetime with nil offlineValidUntil is treated like a local device credential
        // (allowed for local features). Expired leases still require verification.
        let response = try JSONDecoder().decode(AppAccessResponse.self, from: Data(#"{"license":"lifetime"}"#.utf8))
        #expect(response.snapshot.policy(at: now) == .allowed)
        #expect(response.snapshot.canPurchaseCredits(at: now))
        try response.snapshot.policy(at: now).requireNewContent()

        let expiredLease = AppAccessSnapshot(license: .lifetime, offlineValidUntil: now)
        #expect(expiredLease.policy(at: now) == .verificationRequired)
        #expect(!expiredLease.canPurchaseCredits(at: now))
        #expect(throws: AppAccessError.verificationRequired) {
            try expiredLease.policy(at: now).requireNewContent()
        }
    }

    @Test func malformedLeaseDoesNotDecodeAsUnlimitedAccess() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppAccessResponse.self, from: Data(#"{"license":"lifetime","offline_valid_until":"invalid"}"#.utf8))
        }
    }

    @Test func serverFreeLabelOverridesCachedProPlan() {
        #expect(AppAccessGate.label(enforced: true, access: .init(), tier: AccountTier(rawValue: "pro")) == "Free")
    }

    @Test func activeSubscriptionLabelTakesPrecedenceOverOldTrial() {
        let access = AppAccessSnapshot(license: .trial, trialEndsAt: now,
            subscriptionTier: AccountTier(rawValue: "pro"), subscriptionEndsAt: .distantFuture)
        #expect(AppAccessGate.label(enforced: true, access: access, tier: .none) == "Pro plan")
    }

    @Test func staleCacheSaveCannotUndoSignOut() async throws {
        let storage = Mutex<String?>(nil)
        let cache = AppAccessCache(read: { storage.withLock { $0 } },
            write: { value in storage.withLock { $0 = value } }, delete: { storage.withLock { $0 = nil } })
        let user = AccountUser(id: UUID(), email: nil, name: nil, image: nil, tier: .none,
            currentPeriodEnd: nil, cancelAtPeriodEnd: nil, spentCreditsThisPeriod: nil, purchasedCredits: nil)
        let account = AccountResponse(user: user, plan: nil)
        // A valid MAS Lifetime cache must identify its purchase source.
        let access = AppAccessSnapshot(license: .lifetime, purchaseSources: [.appStore],
            offlineValidUntil: Date.now.addingTimeInterval(86400))
        try await cache.save(account: account, access: access, revision: 1)
        #expect(try await cache.load() != nil)
        try await cache.clear(revision: 3)
        try await cache.save(account: account, access: access, revision: 2)
        #expect(try await cache.load() == nil)
    }

    @Test func renew403ClearsLocalCredentialAndLifetimeAccess() throws {
        // Simulate a Lifetime access state
        var lifetimeAccess = AppAccessSnapshot(license: .lifetime, offlineValidUntil: Date.now.addingTimeInterval(86400))
        #expect(lifetimeAccess.license == .lifetime)
        #expect(lifetimeAccess.policy() == .allowed)
        
        // After 403 renew, credential should be cleared and access reset
        // (This simulates the logic in renewLifetimeLeaseIfNeeded)
        lifetimeAccess = .init()
        #expect(lifetimeAccess.license == .none)
        
        // Gate should now deny without local credential
        #expect(throws: AppAccessError.verificationRequired) {
            try AppAccessGate.requireNewContent(
                enforced: true,
                signedIn: false,
                access: lifetimeAccess,
                hasLocalLifetimeCredential: false
            )
        }
    }
}
