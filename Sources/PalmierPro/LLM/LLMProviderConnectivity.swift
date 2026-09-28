import Foundation

enum LLMProviderConnectionError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint
    case unauthorized
    case forbidden
    case rateLimited
    case notFound
    case server(Int)
    case transport(String)
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Enter an API key before testing the connection."
        case .invalidEndpoint:
            "Enter a valid provider base URL."
        case .unauthorized:
            "The API key was rejected. Check the key and provider."
        case .forbidden:
            "The provider denied access. Check the key permissions or project."
        case .rateLimited:
            "The provider is reachable, but this key is currently rate-limited."
        case .notFound:
            "The endpoint does not expose the expected models API."
        case .server(let status):
            "The provider returned a server error (HTTP \(status)). Try again later."
        case .transport(let message):
            "Could not reach the provider: \(message)"
        case .unexpectedStatus(let status):
            "The provider returned an unexpected response (HTTP \(status))."
        }
    }
}

struct LLMProviderConnectivityTester: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func test(profile: LLMProviderProfile, apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsEmptyKey = LLMProviderPreset.isLocalBaseURL(profile.normalizedBaseURL)
        guard !key.isEmpty || allowsEmptyKey else { throw LLMProviderConnectionError.missingAPIKey }
        guard let url = try? profile.modelsEndpoint() else {
            throw LLMProviderConnectionError.invalidEndpoint
        }

        let isRouter = profile.provider == .openRouter || url.host?.lowercased() == "openrouter.ai"
        let testURL = isRouter ? url.deletingLastPathComponent().appendingPathComponent("key") : url
        var request = URLRequest(url: testURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        if !key.isEmpty {
            if profile.provider == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VoxStudio/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMProviderConnectionError.transport("The provider did not return an HTTP response.")
            }
            switch http.statusCode {
            case 200..<300:
                return
            case 401:
                throw LLMProviderConnectionError.unauthorized
            case 403:
                throw LLMProviderConnectionError.forbidden
            case 404:
                throw LLMProviderConnectionError.notFound
            case 429:
                throw LLMProviderConnectionError.rateLimited
            case 500...599:
                throw LLMProviderConnectionError.server(http.statusCode)
            default:
                throw LLMProviderConnectionError.unexpectedStatus(http.statusCode)
            }
        } catch let error as LLMProviderConnectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw LLMProviderConnectionError.transport(error.localizedDescription)
        } catch {
            throw LLMProviderConnectionError.transport(error.localizedDescription)
        }
    }
}

extension LLMProviderProfile {
    func modelsEndpoint() throws -> URL {
        let value = normalizedBaseURL
        guard !value.isEmpty, var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw LLMConfigurationError.invalidEndpoint
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw LLMConfigurationError.insecureEndpoint
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let suffix = ["chat/completions", "messages", "responses", "models"].first(where: { path.hasSuffix($0) }) {
            path = String(path.dropLast(suffix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.path = "/" + ([path, "models"].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let endpoint = components.url else {
            throw LLMConfigurationError.invalidEndpoint
        }
        return endpoint
    }
}
