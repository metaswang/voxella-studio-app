import Foundation

enum VoxellaCalendarOAuthError: LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidCallback
    case stateMismatch
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Google Calendar authorization was cancelled."
        case .invalidCallback:
            "Google Calendar authorization did not return a valid callback."
        case .stateMismatch:
            "Google Calendar authorization could not be verified."
        case .provider(let value):
            value
        }
    }
}

struct VoxellaCalendarOAuthCallback: Equatable, Sendable {
    let code: String
    let state: String
}

struct GoogleCalendarOAuthConnector: Sendable {
    private let browser: any VoxellaAuthBrowserSessioning

    init(browser: any VoxellaAuthBrowserSessioning = ASWebAuthenticationBrowserSession()) {
        self.browser = browser
    }

    func connect(using api: VoxellaAPIClient) async throws -> VoxellaGoogleCalendarStatus {
        let redirectURI = VoxellaAPIConfiguration.googleCalendarRedirectURI
        let start = try await api.beginGoogleCalendarConnection(redirectURI: redirectURI)
        let callback: URL
        do {
            callback = try await browser.start(
                url: start.authURL,
                callbackScheme: VoxellaAPIConfiguration.googleCalendarCallbackScheme
            )
        } catch VoxellaAuthError.cancelled {
            throw VoxellaCalendarOAuthError.cancelled
        }

        let parsedCallback = try Self.parseCallback(callback, expectedState: start.state)

        return try await api.finishGoogleCalendarConnection(
            code: parsedCallback.code,
            state: parsedCallback.state,
            redirectURI: redirectURI,
            codeVerifier: start.codeVerifier
        )
    }

    static func parseCallback(
        _ callback: URL,
        expectedState: String
    ) throws -> VoxellaCalendarOAuthCallback {
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let components else { throw VoxellaCalendarOAuthError.invalidCallback }
        if let providerError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            if providerError == "access_denied" {
                throw VoxellaCalendarOAuthError.cancelled
            }
            throw VoxellaCalendarOAuthError.provider(providerError)
        }
        guard
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            !code.isEmpty,
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
            !state.isEmpty
        else {
            throw VoxellaCalendarOAuthError.invalidCallback
        }
        guard state == expectedState else { throw VoxellaCalendarOAuthError.stateMismatch }
        return VoxellaCalendarOAuthCallback(code: code, state: state)
    }
}

@MainActor
enum MeetBotErrorPresentation {
    static func message(for error: Error) -> String {
        if let error = error as? VoxellaCalendarOAuthError {
            return error.localizedDescription
        }
        if let error = error as? VoxellaAPIError {
            switch error {
            case .unauthorized:
                return L10n.string("Your VoxStudio session has expired. Sign in again to continue.")
            case .http(let code, let rawMessage):
                if code == 402 {
                    return L10n.string("Meet Bot needs at least 30 minutes of available credits before it can start.")
                }
                return serverDetail(from: rawMessage) ?? error.localizedDescription
            case .decoding:
                return L10n.string("VoxStudio returned an unexpected response. Try again.")
            case .missingUploadURL, .cancelled:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    static func access(for error: Error, feature: AccountFeature) -> AccountFeatureAccess? {
        guard let error = error as? VoxellaAPIError else { return nil }
        switch error {
        case .unauthorized:
            return .signedOut
        case .http(let code, _) where code == 403:
            return .upgradeRequired(minimumPlan: feature.minimumPlan)
        default:
            return nil
        }
    }

    private static func serverDetail(from rawMessage: String) -> String? {
        guard let data = rawMessage.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String,
           !detail.isEmpty {
            return detail
        }
        return rawMessage.isEmpty ? nil : rawMessage
    }
}
