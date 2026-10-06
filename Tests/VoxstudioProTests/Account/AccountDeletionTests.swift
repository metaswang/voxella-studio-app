import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Account deletion")
struct AccountDeletionTests {
    @MainActor @Test func acceptedRequestClearsBusyStateOnlyAfterCompletion() async {
        var finish: CheckedContinuation<Void, Never>?
        let store = AccountDeletionStore { _ in
            await withCheckedContinuation { finish = $0 }
        }
        let userID = UUID()
        let operation = Task { await store.deleteAccount(userID: userID) }
        while finish == nil { await Task.yield() }
        #expect(store.isDeleting)
        #expect(!store.wasScheduled)
        // A second click must not send another deletion request.
        await store.deleteAccount(userID: userID)
        finish?.resume()
        await operation.value
        #expect(!store.isDeleting)
        #expect(store.wasScheduled)
        #expect(store.errorMessage == nil)
    }

    @MainActor @Test func failureKeepsAccountAndAllowsRetry() async {
        var requests = 0
        let store = AccountDeletionStore { _ in
            requests += 1
            if requests == 1 { throw VoxellaAPIError.http(503, "Please try again later.") }
        }
        let userID = UUID()
        await store.deleteAccount(userID: userID)
        #expect(store.errorMessage == "Please try again later.")
        #expect(!store.isDeleting)
        #expect(!store.wasScheduled)
        await store.deleteAccount(userID: userID)
        #expect(store.wasScheduled)
        #expect(store.errorMessage == nil)
    }

    @Test func scheduledAndLegacyEmptyResponsesAreAccepted() async throws {
        for token in ["scheduled", "empty"] {
            let (api, auth) = try await fixture(token: token)
            try await api.deleteAccount()
            // API acceptance alone does not clear credentials; AccountService
            // signs out after verifying this is still the confirmed account.
            #expect(await auth.currentAccessToken() == token)
        }
    }

    @Test func serverFailurePreservesAuthentication() async throws {
        let (api, auth) = try await fixture(token: "failure")
        await #expect(throws: VoxellaAPIError.http(503, #"{"detail":"Try again later."}"#)) {
            try await api.deleteAccount()
        }
        #expect(await auth.currentAccessToken() == "failure")
    }

    @Test func expiredAccessTokenRetriesWithRefreshedToken() async throws {
        let (api, auth) = try await fixture(token: "expired")
        try await api.deleteAccount()
        #expect(await auth.currentAccessToken() == "scheduled")
    }

    @Test func staleConfirmationCannotDeleteAnotherSignedInAccount() async throws {
        let (api, auth) = try await fixture(token: "stale")
        let generation = await auth.currentSessionGeneration()
        await auth.signOut()
        _ = try await auth.signInWithEmail(email: "new@example.invalid", password: "fixture")
        await #expect(throws: CancellationError.self) {
            try await api.deleteAccount(authGeneration: generation)
        }
        #expect(await auth.currentAccessToken() == "stale")
    }

    @Test func signedOutDeletionDoesNotStartInteractiveAuthentication() async {
        let auth = VoxellaAuthService(
            tokens: DeletionTokens(token: "stale"), loadRefresh: { nil },
            saveRefresh: { _ in }, deleteRefresh: {}
        )
        let api = client(auth: auth)
        await #expect(throws: VoxellaAuthError.unauthorized) { try await api.deleteAccount() }
    }

    private func fixture(token: String) async throws -> (VoxellaAPIClient, VoxellaAuthService) {
        let auth = VoxellaAuthService(
            tokens: DeletionTokens(token: token), loadRefresh: { "fixture-refresh" },
            saveRefresh: { _ in }, deleteRefresh: {}
        )
        _ = try await auth.signInWithEmail(email: "fixture@example.invalid", password: "fixture")
        return (client(auth: auth), auth)
    }

    private func client(auth: VoxellaAuthService) -> VoxellaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletionURLProtocol.self]
        return VoxellaAPIClient(auth: auth, session: URLSession(configuration: config))
    }
}

private struct DeletionTokens: VoxellaAuthTokenExchanging {
    let token: String
    func exchangeAuthorizationCode(code: String, verifier: String, redirectURI: String) async throws -> VoxellaAuthTokens {
        throw VoxellaAuthError.unauthorized
    }
    func signInWithEmail(email: String, password: String) async throws -> VoxellaAuthTokens {
        .init(accessToken: token, refreshToken: "fixture-refresh", expiresAt: .distantFuture, userID: nil)
    }
    func refresh(refreshToken: String) async throws -> VoxellaAuthTokens {
        .init(accessToken: "scheduled", refreshToken: "fixture-refresh", expiresAt: .distantFuture, userID: nil)
    }
    func revoke(refreshToken: String) async throws {}
}

private final class DeletionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v1/users/me")
        #expect(request.httpBody == nil)
        let status: Int
        let body: String
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer scheduled":
            status = 202
            body = #"{"message":"Account deletion scheduled.","status":"scheduled","apple_subscription_management_url":"https://apps.apple.com/account/subscriptions"}"#
        case "Bearer empty": status = 204; body = ""
        case "Bearer failure": status = 503; body = #"{"detail":"Try again later."}"#
        case "Bearer expired": status = 401; body = "{}"
        default:
            Issue.record("Deletion sent without a valid confirmation/session")
            status = 401; body = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
