import Foundation

enum VoxellaAPIConfiguration {
    static let productionBaseURL = URL(string: "https://voxstudio.me")!
    static let developmentBaseURL = URL(string: "http://localhost:5173")!
    static let clientID = VoxellaAuthService.clientID
    static let redirectURI = VoxellaAuthService.redirectURI
    static let baseURLOverrideEnvironmentKey = "VOXELLA_API_BASE_URL"

    static var baseURL: URL {
        let override = ProcessInfo.processInfo.environment[baseURLOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return productionBaseURL
    }

    static var tokenURL: URL { apiURL("oauth/token") }
    static var googleOneTapURL: URL { apiURL("api/v1/auth/google/one-tap") }
    static var appleTokenURL: URL { apiURL("api/v1/auth/apple/token") }
    static var refreshURL: URL { apiURL("api/v1/auth/refresh") }
    static var logoutURL: URL { apiURL("api/v1/auth/logout") }
    static var sessionsURL: URL { apiURL("api/v1/sessions", isCollection: true) }

    static func authorizationURL(state: String, nonce: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(
            url: apiURL("oauth/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: VoxellaAuthService.defaultScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else {
            throw VoxellaAuthError.browserUnavailable
        }
        return url
    }

    static func sessionURL(_ id: UUID) -> URL {
        sessionsURL.appending(path: apiIdentifier(id), directoryHint: .notDirectory)
    }

    static func apiIdentifier(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func apiURL(_ path: String, isCollection: Bool = false) -> URL {
        baseURL.appending(
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            directoryHint: isCollection ? .isDirectory : .notDirectory
        )
    }

    static func formBody(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=+$@,;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
