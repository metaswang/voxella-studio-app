import Foundation
import Testing
@testable import PalmierPro

@Suite("Voxella desktop auth")
struct VoxellaAuthServiceTests {
    @Test func authorizationURLUsesVoxStudioProductionHost() throws {
        let url = try VoxellaAPIConfiguration.authorizationURL(
            state: "state",
            nonce: "nonce",
            codeChallenge: "challenge"
        )

        #expect(url.scheme == "https")
        #expect(url.host == "voxstudio.me")
        #expect(url.path == "/oauth/authorize")
    }

    @Test func sessionsCollectionURLKeepsTheTrailingSlashRequiredByFastAPI() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        #expect(VoxellaAPIConfiguration.sessionsURL.hasDirectoryPath)
        #expect(VoxellaAPIConfiguration.sessionsURL.absoluteString.hasSuffix("/api/v1/sessions/"))
        #expect(
            VoxellaAPIConfiguration.sessionURL(sessionID).absoluteString
                .hasSuffix("/api/v1/sessions/\(VoxellaAPIConfiguration.apiIdentifier(sessionID))")
        )
        #expect(!VoxellaAPIConfiguration.sessionURL(sessionID).hasDirectoryPath)
        #expect(VoxellaAPIConfiguration.apiURL("api/v1/users/me").absoluteString.hasSuffix("/api/v1/users/me"))
    }

    @Test func signInExchangesCodeAfterStateCheckAndRejectsTokensInCallback() async throws {
        let verifierHolder = VerifierHolder()
        let browser = MockAuthBrowser { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            #expect(items.contains { $0.name == "code_challenge" })
            #expect(items.contains { $0.name == "nonce" })
            #expect(items.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
            return URL(string: "voxella-studio://oauth/callback?code=one-time-code&state=\(state)")!
        }
        let tokens = MockTokenClient(
            onExchange: { code, verifier, redirect in
                #expect(code == "one-time-code")
                #expect(redirect == VoxellaAuthService.redirectURI)
                #expect(!verifier.isEmpty)
                verifierHolder.value = verifier
                return VoxellaAuthTokens(
                    accessToken: "access-memory-only",
                    refreshToken: "refresh-keychain-only",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let store = MemoryRefreshStore()
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: tokens,
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        let access = try await auth.signIn()
        #expect(access == "access-memory-only")
        #expect(store.value == "refresh-keychain-only")
        #expect(await auth.currentAccessToken() == "access-memory-only")
    }

    @Test func persistedRefreshTokenRestoresAfterAuthServiceIsRecreated() async throws {
        let store = MemoryRefreshStore()
        let firstAuth = VoxellaAuthService(
            browser: MockAuthBrowser { url in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first { $0.name == "state" }?
                    .value ?? ""
                return URL(string: "voxella-studio://oauth/callback?code=first-login&state=\(state)")!
            },
            tokens: MockTokenClient(
                onExchange: { _, _, _ in
                    VoxellaAuthTokens(
                        accessToken: "first-access",
                        refreshToken: "persisted-refresh",
                        expiresAt: Date().addingTimeInterval(3600),
                        userID: nil
                    )
                }
            ),
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        _ = try await firstAuth.signIn()
        #expect(store.value == "persisted-refresh")

        let browserOpened = Flag()
        let restoredAuth = VoxellaAuthService(
            browser: MockAuthBrowser { _ in
                browserOpened.value = true
                throw VoxellaAuthError.browserUnavailable
            },
            tokens: MockTokenClient(
                onRefresh: { refreshToken in
                    #expect(refreshToken == "persisted-refresh")
                    return VoxellaAuthTokens(
                        accessToken: "restored-access",
                        refreshToken: "rotated-refresh",
                        expiresAt: Date().addingTimeInterval(3600),
                        userID: nil
                    )
                }
            ),
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        let access = try await restoredAuth.ensureSignedIn()
        #expect(access == "restored-access")
        #expect(store.value == "rotated-refresh")
        #expect(browserOpened.value == false)
    }

    @Test func signOutDeletesPersistedRefreshToken() async {
        let store = MemoryRefreshStore(value: "persisted-refresh")
        let auth = VoxellaAuthService(
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        await auth.signOut()

        #expect(store.value == nil)
        #expect(await auth.currentAccessToken() == nil)
    }

    @Test func callbackWithAccessTokenIsRejected() async {
        let browser = MockAuthBrowser { _ in
            URL(string: "voxella-studio://oauth/callback?code=abc&state=x&access_token=stolen")!
        }
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: MockTokenClient(),
            loadRefresh: { nil },
            saveRefresh: { _ in },
            deleteRefresh: {}
        )
        await #expect(throws: VoxellaAuthError.invalidCallback) {
            _ = try await auth.signIn()
        }
        #expect(await auth.currentAccessToken() == nil)
    }

    @Test func cancelledSignInDoesNotStoreTokens() async {
        let browserOpened = Flag()
        let browser = MockAuthBrowser { _ in
            browserOpened.value = true
            throw VoxellaAuthError.cancelled
        }
        let store = MemoryRefreshStore()
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: MockTokenClient(),
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )
        await #expect(throws: VoxellaAuthError.cancelled) {
            _ = try await auth.ensureSignedIn()
        }
        #expect(store.value == nil)
        #expect(await auth.currentAccessToken() == nil)
        #expect(browserOpened.value)
    }

    @Test func appleSignInUsesTheBrowserOAuthFlow() async throws {
        let browserOpened = Flag()
        let browser = MockAuthBrowser { url in
            browserOpened.value = true
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "state" }?
                .value ?? ""
            return URL(string: "voxella-studio://oauth/callback?code=web-code&state=\(state)")!
        }
        let tokens = MockTokenClient(
            onExchange: { code, _, _ in
                #expect(code == "web-code")
                return VoxellaAuthTokens(
                    accessToken: "web-access",
                    refreshToken: "web-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: tokens,
            loadRefresh: { nil },
            saveRefresh: { _ in },
            deleteRefresh: {}
        )

        let access = try await auth.signInWithApple()

        #expect(access == "web-access")
        #expect(browserOpened.value)
    }

    @Test func googleSignInUsesTheBrowserOAuthFlow() async throws {
        let browserOpened = Flag()
        let browser = MockAuthBrowser { url in
            browserOpened.value = true
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "state" }?
                .value ?? ""
            return URL(string: "voxella-studio://oauth/callback?code=google-web-code&state=\(state)")!
        }
        let tokens = MockTokenClient(
            onExchange: { code, _, _ in
                #expect(code == "google-web-code")
                return VoxellaAuthTokens(
                    accessToken: "google-web-access",
                    refreshToken: "google-web-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: tokens,
            loadRefresh: { nil },
            saveRefresh: { _ in },
            deleteRefresh: {}
        )

        let access = try await auth.signInWithGoogle()

        #expect(access == "google-web-access")
        #expect(browserOpened.value)
    }

    @Test func emailSignInStoresTokensWithoutOpeningTheBrowser() async throws {
        let browserOpened = Flag()
        let store = MemoryRefreshStore()
        let tokens = MockTokenClient(
            onEmail: { email, password in
                #expect(email == "person@example.com")
                #expect(password == "correct horse battery staple")
                return VoxellaAuthTokens(
                    accessToken: "email-access",
                    refreshToken: "email-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let auth = VoxellaAuthService(
            browser: MockAuthBrowser { _ in
                browserOpened.value = true
                throw VoxellaAuthError.browserUnavailable
            },
            tokens: tokens,
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        let access = try await auth.signInWithEmail(
            email: "  person@example.com  ",
            password: "correct horse battery staple"
        )

        #expect(access == "email-access")
        #expect(store.value == "email-refresh")
        #expect(browserOpened.value == false)
    }

    @Test func emailSignInRejectsMissingCredentialsBeforeRequestingTokens() async {
        let requested = Flag()
        let auth = VoxellaAuthService(
            browser: MockAuthBrowser { _ in throw VoxellaAuthError.browserUnavailable },
            tokens: MockTokenClient(
                onEmail: { _, _ in
                    requested.value = true
                    throw VoxellaAuthError.tokenExchangeFailed("unexpected request")
                }
            ),
            loadRefresh: { nil },
            saveRefresh: { _ in },
            deleteRefresh: {}
        )

        await #expect(throws: VoxellaAuthError.tokenExchangeFailed("Enter your email and password.")) {
            _ = try await auth.signInWithEmail(email: "", password: "")
        }
        #expect(requested.value == false)
    }

    @Test func ensureSignedInUsesTheBrowserOAuthFlow() async throws {
        let browserOpened = Flag()
        let browser = MockAuthBrowser { url in
            browserOpened.value = true
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            #expect(url.path == "/oauth/authorize")
            return URL(string: "voxella-studio://oauth/callback?code=web-code&state=\(state)")!
        }
        let tokens = MockTokenClient(
            onExchange: { code, _, _ in
                #expect(code == "web-code")
                return VoxellaAuthTokens(
                    accessToken: "web-access",
                    refreshToken: "web-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let store = MemoryRefreshStore()
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: tokens,
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )
        let access = try await auth.ensureSignedIn()
        #expect(access == "web-access")
        #expect(browserOpened.value == true)
        #expect(store.value == "web-refresh")
    }

    @Test func concurrentEnsureSignedInOpensTheBrowserOnce() async throws {
        let browserCount = Counter()
        let started = Gate()
        let release = Gate()
        let browser = MockAuthBrowser { url in
            browserCount.value += 1
            await started.open()
            await release.wait()
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            return URL(string: "voxella-studio://oauth/callback?code=shared-code&state=\(state)")!
        }
        let tokens = MockTokenClient(
            onExchange: { code, _, _ in
                #expect(code == "shared-code")
                return VoxellaAuthTokens(
                    accessToken: "shared-access",
                    refreshToken: "shared-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    userID: UUID()
                )
            }
        )
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: tokens,
            loadRefresh: { nil },
            saveRefresh: { _ in },
            deleteRefresh: {}
        )
        async let first = auth.ensureSignedIn()
        async let second = auth.ensureSignedIn()
        await started.wait()
        #expect(browserCount.value == 1)
        await release.open()
        let access = try await first
        let other = try await second
        #expect(access == "shared-access")
        #expect(other == "shared-access")
        #expect(browserCount.value == 1)
    }

    @Test func refreshIsSerializedAndClearsMemoryAccessOnUnauthorized() async throws {
        let store = MemoryRefreshStore(value: "refresh-1")
        let tokens = MockTokenClient(
            onRefresh: { token in
                #expect(token == "refresh-1")
                throw VoxellaAuthError.unauthorized
            }
        )
        let auth = VoxellaAuthService(
            browser: MockAuthBrowser { _ in throw VoxellaAuthError.browserUnavailable },
            tokens: tokens,
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )
        await #expect(throws: VoxellaAuthError.refreshFailed) {
            _ = try await auth.refreshAccessToken()
        }
        #expect(store.value == nil)
        #expect(await auth.currentAccessToken() == nil)
    }

    @Test func validAccessTokenDoesNotOpenBrowser() async throws {
        let store = MemoryRefreshStore(value: "refresh-1")
        let browserOpened = Flag()
        let browser = MockAuthBrowser { _ in
            browserOpened.value = true
            throw VoxellaAuthError.browserUnavailable
        }
        let auth = VoxellaAuthService(
            browser: browser,
            tokens: MockTokenClient(
                onRefresh: { _ in
                    VoxellaAuthTokens(
                        accessToken: "refreshed",
                        refreshToken: "refresh-2",
                        expiresAt: Date().addingTimeInterval(3600),
                        userID: nil
                    )
                }
            ),
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )
        let token = try await auth.ensureSignedIn()
        #expect(token == "refreshed")
        #expect(browserOpened.value == false)
        #expect(store.value == "refresh-2")
    }

    @Test func transientRefreshFailureKeepsPersistedSessionAndDoesNotOpenBrowser() async {
        let store = MemoryRefreshStore(value: "refresh-1")
        let browserOpened = Flag()
        let auth = VoxellaAuthService(
            browser: MockAuthBrowser { _ in
                browserOpened.value = true
                throw VoxellaAuthError.browserUnavailable
            },
            tokens: MockTokenClient(
                onRefresh: { _ in
                    throw VoxellaAuthError.tokenExchangeFailed("temporarily unavailable")
                }
            ),
            loadRefresh: { store.value },
            saveRefresh: { store.value = $0 },
            deleteRefresh: { store.value = nil }
        )

        await #expect(throws: VoxellaAuthError.refreshUnavailable) {
            _ = try await auth.ensureSignedIn()
        }

        #expect(store.value == "refresh-1")
        #expect(browserOpened.value == false)
    }
}

private final class MemoryRefreshStore: @unchecked Sendable {
    var value: String?
    init(value: String? = nil) { self.value = value }
}

private final class VerifierHolder: @unchecked Sendable {
    var value = ""
}

private final class Flag: @unchecked Sendable {
    var value = false
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct MockAuthBrowser: VoxellaAuthBrowserSessioning {
    var handler: @Sendable (URL) async throws -> URL

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await handler(url)
    }
}

private struct MockTokenClient: VoxellaAuthTokenExchanging {
    var onExchange: (@Sendable (String, String, String) async throws -> VoxellaAuthTokens)?
    var onEmail: (@Sendable (String, String) async throws -> VoxellaAuthTokens)?
    var onRefresh: (@Sendable (String) async throws -> VoxellaAuthTokens)?
    var onRevoke: (@Sendable (String) async throws -> Void)?

    func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> VoxellaAuthTokens {
        guard let onExchange else { throw VoxellaAuthError.tokenExchangeFailed("unused") }
        return try await onExchange(code, verifier, redirectURI)
    }

    func signInWithEmail(email: String, password: String) async throws -> VoxellaAuthTokens {
        guard let onEmail else { throw VoxellaAuthError.tokenExchangeFailed("unused") }
        return try await onEmail(email, password)
    }

    func refresh(refreshToken: String) async throws -> VoxellaAuthTokens {
        guard let onRefresh else { throw VoxellaAuthError.refreshFailed }
        return try await onRefresh(refreshToken)
    }

    func revoke(refreshToken: String) async throws {
        try await onRevoke?(refreshToken)
    }
}
