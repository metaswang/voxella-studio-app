import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum VoxellaAuthError: LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidCallback
    case stateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed
    case refreshUnavailable
    case unauthorized
    case missingRefreshToken
    case browserUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "VoxStudio sign-in was cancelled."
        case .invalidCallback:
            "The sign-in callback was missing a one-time code."
        case .stateMismatch:
            "The sign-in callback could not be verified."
        case .tokenExchangeFailed(let message):
            message
        case .refreshFailed:
            "VoxStudio sign-in expired. Sign in again to continue."
        case .refreshUnavailable:
            "VoxStudio could not restore your session. Check your connection and try again."
        case .unauthorized:
            "VoxStudio sign-in is required for this task."
        case .missingRefreshToken:
            "VoxStudio sign-in is required for this task."
        case .browserUnavailable:
            "Unable to open the VoxStudio sign-in page."
        }
    }
}

struct VoxellaAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var userID: UUID?
}

protocol VoxellaAuthBrowserSessioning: Sendable {
    func start(url: URL, callbackScheme: String) async throws -> URL
}

protocol VoxellaAuthTokenExchanging: Sendable {
    func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> VoxellaAuthTokens
    func signInWithEmail(email: String, password: String) async throws -> VoxellaAuthTokens
    func refresh(refreshToken: String) async throws -> VoxellaAuthTokens
    func revoke(refreshToken: String) async throws
}

struct ASWebAuthenticationBrowserSession: VoxellaAuthBrowserSessioning {
    func start(url: URL, callbackScheme: String) async throws -> URL {
        let controller = await MainActor.run { ASWebAuthenticationSessionController() }
        return try await controller.start(url: url, callbackScheme: callbackScheme)
    }
}

@MainActor
final class ASWebAuthenticationSessionController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let onComplete: @Sendable (URL?, (any Error)?) -> Void = { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.finish(callbackURL: callbackURL, error: error)
                }
            }
            let session = Self.makeSession(
                url: url,
                callbackScheme: callbackScheme,
                onComplete: onComplete
            )
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                finish(callbackURL: nil, error: VoxellaAuthError.browserUnavailable)
            }
        }
    }

    nonisolated private static func makeSession(
        url: URL,
        callbackScheme: String,
        onComplete: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme,
            completionHandler: onComplete
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func finish(callbackURL: URL?, error: Error?) {
        session = nil
        let continuation = continuation
        self.continuation = nil
        guard let continuation else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                continuation.resume(throwing: VoxellaAuthError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        guard let callbackURL else {
            continuation.resume(throwing: VoxellaAuthError.invalidCallback)
            return
        }
        continuation.resume(returning: callbackURL)
    }
}

actor VoxellaAuthService {
    static let shared = VoxellaAuthService()

    static let clientID = "voxella-studio-desktop"
    static let callbackScheme = "voxella-studio"
    static let redirectURI = "voxella-studio://oauth/callback"
    static let refreshAccount = "voxella.auth.refresh"
    static let defaultScopes = "voxstudio.sessions.read voxstudio.sessions.write voxstudio.media.read voxstudio.transcripts.read"

    private let browser: any VoxellaAuthBrowserSessioning
    private let tokens: any VoxellaAuthTokenExchanging
    private let now: @Sendable () -> Date
    private let loadRefresh: @Sendable () throws -> String?
    private let saveRefresh: @Sendable (String) throws -> Void
    private let deleteRefresh: @Sendable () throws -> Void

    private var accessToken: String?
    private var accessExpiresAt: Date?
    private var refreshTask: Task<String, Error>?
    private var signInWaiters: [CheckedContinuation<String, Error>] = []
    private var isInteractiveSignInRunning = false
    private var pendingPKCE: PendingPKCE?

    private struct PendingPKCE: Sendable {
        var state: String
        var nonce: String
        var verifier: String
    }

    init(
        browser: any VoxellaAuthBrowserSessioning = ASWebAuthenticationBrowserSession(),
        tokens: any VoxellaAuthTokenExchanging = VoxellaAuthTokenClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        loadRefresh: @escaping @Sendable () throws -> String? = {
            try KeychainStore.loadThisDeviceOnly(account: VoxellaAuthService.refreshAccount)
        },
        saveRefresh: @escaping @Sendable (String) throws -> Void = { value in
            try KeychainStore.saveThisDeviceOnly(value, account: VoxellaAuthService.refreshAccount)
        },
        deleteRefresh: @escaping @Sendable () throws -> Void = {
            try KeychainStore.deleteThisDeviceOnly(account: VoxellaAuthService.refreshAccount)
        }
    ) {
        self.browser = browser
        self.tokens = tokens
        self.now = now
        self.loadRefresh = loadRefresh
        self.saveRefresh = saveRefresh
        self.deleteRefresh = deleteRefresh
    }

    func hasValidAccessToken(leeway: TimeInterval = 60) -> Bool {
        guard let accessToken, !accessToken.isEmpty, let accessExpiresAt else { return false }
        return accessExpiresAt.timeIntervalSince(now()) > leeway
    }

    func currentAccessToken() -> String? {
        accessToken
    }

    func ensureSignedIn(anchorNow: Date? = nil) async throws -> String {
        _ = anchorNow
        if let token = try await validAccessToken() {
            return token
        }
        if isInteractiveSignInRunning {
            return try await withCheckedThrowingContinuation { continuation in
                signInWaiters.append(continuation)
            }
        }
        isInteractiveSignInRunning = true
        do {
            let token = try await performInteractiveSignIn()
            finishInteractiveSignIn(.success(token))
            return token
        } catch {
            finishInteractiveSignIn(.failure(error))
            throw error
        }
    }

    private func finishInteractiveSignIn(_ result: Result<String, Error>) {
        let waiters = signInWaiters
        signInWaiters = []
        isInteractiveSignInRunning = false
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func performInteractiveSignIn() async throws -> String {
        if let token = try await validAccessToken() {
            return token
        }
        Log.account.notice(
            "voxstudio sign-in starting provider=browser_oauth host=\(VoxellaAPIConfiguration.baseURL.host ?? "")",
            telemetry: "VoxStudio sign-in starting",
            data: [
                "provider": "browser_oauth",
                "host": VoxellaAPIConfiguration.baseURL.host ?? "",
            ]
        )
        return try await signInWithApple()
    }

    func validAccessToken() async throws -> String? {
        if hasValidAccessToken() {
            return accessToken
        }
        guard (try loadRefresh()) != nil else { return nil }
        do {
            return try await refreshAccessToken()
        } catch VoxellaAuthError.refreshFailed, VoxellaAuthError.unauthorized {
            return nil
        }
    }

    func signInWithGoogle() async throws -> String {
        try await signIn()
    }

    func signInWithApple() async throws -> String {
        try await signIn()
    }

    func signInWithEmail(email: String, password: String) async throws -> String {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            throw VoxellaAuthError.tokenExchangeFailed("Enter your email and password.")
        }
        let pair = try await tokens.signInWithEmail(email: normalizedEmail, password: password)
        try store(pair)
        Log.account.notice(
            "voxstudio sign-in completed",
            telemetry: "VoxStudio sign-in completed",
            data: ["provider": "email"]
        )
        return pair.accessToken
    }

    func signIn() async throws -> String {
        let verifier = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(24)
        let nonce = Self.randomURLSafe(24)
        pendingPKCE = PendingPKCE(state: state, nonce: nonce, verifier: verifier)
        let authorizeURL = try VoxellaAPIConfiguration.authorizationURL(
            state: state,
            nonce: nonce,
            codeChallenge: Self.codeChallenge(for: verifier)
        )
        let callback: URL
        do {
            callback = try await browser.start(
                url: authorizeURL,
                callbackScheme: Self.callbackScheme
            )
        } catch {
            pendingPKCE = nil
            throw error
        }
        guard let pending = pendingPKCE else {
            throw VoxellaAuthError.invalidCallback
        }
        pendingPKCE = nil
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        guard items["access_token"] == nil, items["refresh_token"] == nil else {
            throw VoxellaAuthError.invalidCallback
        }
        guard items["state"] == pending.state else {
            throw VoxellaAuthError.stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            throw VoxellaAuthError.invalidCallback
        }
        let pair = try await tokens.exchangeAuthorizationCode(
            code: code,
            verifier: pending.verifier,
            redirectURI: Self.redirectURI
        )
        try store(pair)
        Log.account.notice("voxstudio sign-in completed", telemetry: "VoxStudio sign-in completed")
        return pair.accessToken
    }

    func refreshAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<String, Error> {
            guard let refreshToken = try self.loadRefresh(), !refreshToken.isEmpty else {
                throw VoxellaAuthError.missingRefreshToken
            }
            do {
                let pair = try await self.tokens.refresh(refreshToken: refreshToken)
                try self.store(pair)
                return pair.accessToken
            } catch VoxellaAuthError.unauthorized {
                try? self.deleteRefresh()
                self.clearMemoryTokens()
                throw VoxellaAuthError.refreshFailed
            } catch VoxellaAuthError.refreshFailed {
                self.clearMemoryTokens()
                throw VoxellaAuthError.refreshFailed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VoxellaAuthError.refreshUnavailable
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func signOut() async {
        let refreshToken = try? loadRefresh()
        if let refreshToken, !refreshToken.isEmpty {
            try? await tokens.revoke(refreshToken: refreshToken)
        }
        try? deleteRefresh()
        clearMemoryTokens()
    }

    func authorizedAccessToken() async throws -> String {
        if let token = try await validAccessToken() {
            return token
        }
        throw VoxellaAuthError.unauthorized
    }

    private func store(_ pair: VoxellaAuthTokens) throws {
        if let refresh = pair.refreshToken, !refresh.isEmpty {
            try saveRefresh(refresh)
        }
        accessToken = pair.accessToken
        accessExpiresAt = pair.expiresAt
    }

    private func clearMemoryTokens() {
        accessToken = nil
        accessExpiresAt = nil
    }

    static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct VoxellaAuthTokenClient: VoxellaAuthTokenExchanging {
    func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> VoxellaAuthTokens {
        var request = URLRequest(url: VoxellaAPIConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = VoxellaAPIConfiguration.formBody([
            "grant_type": "authorization_code",
            "client_id": VoxellaAuthService.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return try await decodeTokenResponse(request)
    }

    func signInWithEmail(email: String, password: String) async throws -> VoxellaAuthTokens {
        var request = URLRequest(url: VoxellaAPIConfiguration.passwordTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PasswordLoginBody(
            email: email,
            password: password,
            clientID: VoxellaAuthService.clientID
        ))
        return try await decodeTokenResponse(request)
    }

    func refresh(refreshToken: String) async throws -> VoxellaAuthTokens {
        var request = URLRequest(url: VoxellaAPIConfiguration.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RefreshBody(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientID: VoxellaAuthService.clientID
        ))
        return try await decodeTokenResponse(request, invalidSession: true)
    }

    func revoke(refreshToken: String) async throws {
        var request = URLRequest(url: VoxellaAPIConfiguration.logoutURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LogoutBody(refreshToken: refreshToken))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return
        }
    }

    private func decodeTokenResponse(
        _ request: URLRequest,
        invalidSession: Bool = false
    ) async throws -> VoxellaAuthTokens {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxellaAuthError.tokenExchangeFailed("The VoxStudio token endpoint did not respond.")
        }
        if http.statusCode == 401, invalidSession {
            throw VoxellaAuthError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.tokenEndpointMessage(status: http.statusCode, data: data)
            Log.account.warning(
                "token exchange failed status=\(http.statusCode)",
                telemetry: "Token exchange failed",
                data: ["status": http.statusCode, "message": message]
            )
            throw VoxellaAuthError.tokenExchangeFailed(message)
        }
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        guard !payload.accessToken.isEmpty else {
            throw VoxellaAuthError.tokenExchangeFailed("The VoxStudio token response was empty.")
        }
        let expires = Date().addingTimeInterval(TimeInterval(payload.expiresIn ?? 3600))
        return VoxellaAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: expires,
            userID: payload.user?.id
        )
    }

    private static func tokenEndpointMessage(status: Int, data: Data) -> String {
        if let detail = tokenEndpointDetail(data), !detail.isEmpty {
            return detail
        }
        if status == 401 {
            return "VoxStudio could not verify this sign-in."
        }
        return "VoxStudio sign-in failed (\(status))."
    }

    private static func tokenEndpointDetail(_ data: Data) -> String? {
        struct DetailPayload: Decodable {
            var detail: DetailValue?

            enum DetailValue: Decodable {
                case text(String)
                case items([[String: String]])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) {
                        self = .text(text)
                        return
                    }
                    self = .items((try? container.decode([[String: String]].self)) ?? [])
                }
            }
        }
        guard let payload = try? JSONDecoder().decode(DetailPayload.self, from: data) else {
            return nil
        }
        switch payload.detail {
        case .text(let text):
            return text
        case .items(let items):
            let messages = items.compactMap { $0["msg"] ?? $0["message"] }.filter { !$0.isEmpty }
            return messages.isEmpty ? nil : messages.joined(separator: " ")
        case nil:
            return nil
        }
    }

    private struct RefreshBody: Encodable {
        var grantType: String
        var refreshToken: String
        var clientID: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
            case clientID = "client_id"
        }
    }

    private struct PasswordLoginBody: Encodable {
        let grantType: String
        let email: String
        let password: String
        let clientID: String

        init(email: String, password: String, clientID: String) {
            self.grantType = "password"
            self.email = email
            self.password = password
            self.clientID = clientID
        }

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case email
            case password
            case clientID = "client_id"
        }
    }

    private struct GoogleIdentityBody: Encodable {
        let credential: String
        let clientID: String

        enum CodingKeys: String, CodingKey {
            case credential
            case clientID = "client_id"
        }
    }

    private struct LogoutBody: Encodable {
        var refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenPayload: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int?
        var user: UserPayload?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
        }
    }

    private struct UserPayload: Decodable {
        var id: UUID?
    }
}
