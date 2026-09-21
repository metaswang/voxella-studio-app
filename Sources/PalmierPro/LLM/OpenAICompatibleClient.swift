import Foundation

protocol LLMTextClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

struct OpenAICompatibleClient: LLMConfigurableTextClient {
    static let maximumConnectionsPerHost = 32

    let configuration: LLMRuntimeConfiguration
    let policy: LLMRequestPolicy
    let session: URLSession

    init(
        configuration: LLMRuntimeConfiguration,
        policy: LLMRequestPolicy = .default(for: .subtitleProcessing),
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.policy = policy
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = policy.timeoutSeconds
            sessionConfiguration.timeoutIntervalForResource = policy.timeoutSeconds
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.httpMaximumConnectionsPerHost = Self.maximumConnectionsPerHost
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    func complete(system: String, user: String) async throws -> String {
        try await complete(
            system: system,
            user: user,
            options: .default
        )
    }

    func complete(
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String {
        var request = URLRequest(
            url: configuration.endpoint,
            timeoutInterval: policy.timeoutSeconds
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-ID")
        var extraBody = configuration.resolvedExtraBody
        if let structuredOutput = options.structuredOutput {
            // Request-scoped structured output must win over an old provider
            // override so the selector cannot silently return free-form text.
            extraBody["response_format"] = structuredOutput.chatCompletionsValue
        }
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: configuration.modelName,
                messages: [
                    .init(role: "system", content: system),
                    .init(role: "user", content: user),
                ],
                extraBody: extraBody
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMClientError.timeout
            }
            throw LLMClientError.transport(
                code: error.code.rawValue,
                message: error.localizedDescription
            )
        } catch {
            throw LLMClientError.transport(code: nil, message: error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.providerErrorMessage(from: data)
            Log.llm.warning(
                "provider error \(configuration.diagnosticDescription) status=\(http.statusCode) bytes=\(data.count) message=\(message ?? "none") body=\(LLMDiagnostics.preview(data))"
            )
            throw LLMClientError.provider(
                status: http.statusCode,
                message: message,
                retryAfterSeconds: Self.retryAfterSeconds(from: http)
            )
        }
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            Log.llm.warning(
                "invalid response \(configuration.diagnosticDescription) bytes=\(data.count) body=\(LLMDiagnostics.preview(data)) error=\(String(describing: error))"
            )
            throw LLMClientError.invalidResponse
        }
        guard let content = decoded.choices.first?.message.textContent?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            Log.llm.warning(
                "empty response \(configuration.diagnosticDescription) bytes=\(data.count) body=\(LLMDiagnostics.preview(data))"
            )
            throw LLMClientError.emptyResponse
        }
        return content
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = root["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["msg"] as? String)
        }
        if let baseResponse = root["base_resp"] as? [String: Any] {
            return baseResponse["status_msg"] as? String
        }
        return root["message"] as? String
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Double(value),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return min(seconds, 30)
    }
}

struct ResilientLLMTextClient: LLMConfigurableTextClient {
    typealias ClientFactory = @Sendable (LLMRuntimeConfiguration, LLMRequestPolicy) -> any LLMTextClient
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let route: LLMRuntimeRoute
    private let clients: [ClientEntry]
    private let sleeper: Sleeper
    private static let slowRequestLogThresholdMilliseconds = 10_000

    private struct ClientEntry: Sendable {
        let configuration: LLMRuntimeConfiguration
        let client: any LLMTextClient
    }

    init(
        route: LLMRuntimeRoute,
        clientFactory: ClientFactory? = nil,
        sleeper: Sleeper? = nil
    ) {
        self.route = route
        let clientFactory = clientFactory ?? {
            OpenAICompatibleClient(configuration: $0, policy: $1)
        }
        self.clients = route.configurations.map {
            ClientEntry(
                configuration: $0,
                client: clientFactory($0, route.policy)
            )
        }
        self.sleeper = sleeper ?? { try await Task.sleep(for: $0) }
    }

    func complete(system: String, user: String) async throws -> String {
        try await complete(
            system: system,
            user: user,
            options: .default
        )
    }

    func complete(
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String {
        var failures: [LLMAttemptFailure] = []
        let attempts = route.policy.maximumAttemptsPerModel

        for attempt in 1...attempts {
            var retryDelay: Double?
            for entry in clients {
                try Task.checkCancellation()
                let startedAt = Date()
                do {
                    let result = try await Self.complete(
                        entry.client,
                        system: system,
                        user: user,
                        options: options
                    )
                    let elapsedMilliseconds = Self.elapsedMilliseconds(since: startedAt)
                    if !failures.isEmpty {
                        Log.llm.notice(
                            "request recovered use_case=\(route.useCase.rawValue) model=\(entry.configuration.modelIdentifier) attempt=\(attempt) elapsed_ms=\(elapsedMilliseconds)"
                        )
                    } else if elapsedMilliseconds >= Self.slowRequestLogThresholdMilliseconds {
                        Log.llm.notice(
                            "slow request use_case=\(route.useCase.rawValue) model=\(entry.configuration.modelIdentifier) attempt=\(attempt) elapsed_ms=\(elapsedMilliseconds)"
                        )
                    }
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let elapsedMilliseconds = Self.elapsedMilliseconds(since: startedAt)
                    let failure = LLMAttemptFailure(
                        model: entry.configuration.modelIdentifier,
                        attempt: attempt,
                        reason: Self.failureDescription(error),
                        detail: Self.failureDetail(error)
                    )
                    failures.append(failure)
                    let retryable = Self.isRetryable(error)
                    Log.llm.warning(
                        "request failed \(entry.configuration.diagnosticDescription) attempt=\(attempt) elapsed_ms=\(elapsedMilliseconds) retryable=\(retryable) reason=\(failure.reason) detail=\(Self.failureDetail(error))"
                    )
                    guard retryable else { continue }
                    let delay = Self.retryDelay(
                        error: error,
                        attempt: attempt,
                        initial: route.policy.initialBackoffSeconds
                    )
                    retryDelay = max(retryDelay ?? 0, delay)
                }
            }
            guard attempt < attempts, let retryDelay, retryDelay > 0 else { break }
            try await sleeper(.seconds(retryDelay))
        }
        Log.llm.warning(
            "request exhausted \(route.diagnosticDescription) failures=\(LLMClientError.failureSummary(failures))"
        )
        throw LLMClientError.exhausted(failures)
    }

    private static func complete(
        _ client: any LLMTextClient,
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String {
        if let configurable = client as? any LLMConfigurableTextClient {
            return try await configurable.complete(system: system, user: user, options: options)
        }
        return try await client.complete(system: system, user: user)
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? LLMClientError else { return true }
        switch error {
        case .provider(let status, _, _):
            return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
        case .timeout, .transport, .nonHTTPResponse, .invalidResponse, .emptyResponse:
            return true
        case .insufficientCredits:
            return false
        case .exhausted:
            return false
        }
    }

    static func retryDelay(
        error: Error,
        attempt: Int,
        initial: Double
    ) -> Double {
        if let clientError = error as? LLMClientError,
           case .provider(_, _, let retryAfter) = clientError,
           let retryAfter {
            return retryAfter
        }
        return min(initial * pow(2, Double(max(0, attempt - 1))), 10)
    }

    private static func failureDescription(_ error: Error) -> String {
        if let clientError = error as? LLMClientError {
            return clientError.shortDescription
        }
        return String(describing: type(of: error))
    }

    private static func failureDetail(_ error: Error) -> String {
        if let error = error as? LLMClientError {
            return error.logDescription
        }
        return String(describing: error)
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let extraBody: [String: LLMJSONValue]

    private struct CodingKeyValue: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) { return nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeyValue.self)
        let reservedKeys = Set(["model", "messages"])
        for (key, value) in extraBody where !reservedKeys.contains(key) {
            try container.encode(value, forKey: CodingKeyValue(stringValue: key))
        }
        try container.encode(model, forKey: CodingKeyValue(stringValue: "model"))
        try container.encode(messages, forKey: CodingKeyValue(stringValue: "messages"))
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            private enum CodingKeys: String, CodingKey {
                case content
            }

            let textContent: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                    textContent = text
                    return
                }
                if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                    textContent = parts.compactMap(\.text).joined()
                    return
                }
                textContent = nil
            }
        }

        let message: Message
    }

    struct ContentPart: Decodable {
        let text: String?
    }

    let choices: [Choice]
}

struct LLMAttemptFailure: Equatable, Sendable {
    let model: String
    let attempt: Int
    let reason: String
    let detail: String

    init(model: String, attempt: Int, reason: String, detail: String = "") {
        self.model = model
        self.attempt = attempt
        self.reason = reason
        self.detail = detail
    }
}

enum LLMClientError: LocalizedError, Sendable {
    case nonHTTPResponse
    case timeout
    case transport(code: Int?, message: String)
    case provider(status: Int, message: String?, retryAfterSeconds: Double?)
    case insufficientCredits(String)
    case invalidResponse
    case emptyResponse
    case exhausted([LLMAttemptFailure])

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "The AI service returned an unexpected response. Try again later."
        case .timeout:
            return "The AI request took too long. Try again."
        case .transport, .provider, .insufficientCredits:
            return "The AI service cannot complete the request right now. Try again later."
        case .invalidResponse:
            return "The AI service returned an unsupported response. Try again later."
        case .emptyResponse:
            return "The AI service returned no answer. Try again."
        case .exhausted:
            return "The AI service cannot complete the request right now. Try again later."
        }
    }

    private static func openRouterAuthenticationRecoveryMessage(
        for failures: [LLMAttemptFailure]
    ) -> String? {
        guard !failures.isEmpty,
              failures.allSatisfy({
                  $0.reason == "http_401" && $0.model.hasPrefix("openrouter/")
              }) else {
            return nil
        }
        return """
        OpenRouter couldn't verify the saved API key, so this AI task wasn't completed.

        Try one of these:
        • In Settings → AI Service, confirm the OpenRouter key is the correct, complete key for this account.
        • In OpenRouter, check whether the key has been disabled, revoked, or expired.
        • Check the key's workspace, spending limit, and available account credits.
        • Replace the saved key with a new active OpenRouter key, then try again.

        Technical details: \(failureSummary(failures)).
        """
    }

    static func failureSummary(_ failures: [LLMAttemptFailure]) -> String {
        failures
            .suffix(4)
            .map { failure in
                let detail = failure.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty || detail == failure.reason {
                    return "\(failure.model) (\(failure.reason))"
                }
                return "\(failure.model) (\(failure.reason): \(detail))"
            }
            .joined(separator: "; ")
    }

    var shortDescription: String {
        switch self {
        case .nonHTTPResponse: "non_http_response"
        case .timeout: "timeout"
        case .transport(let code, _):
            code.map { "transport_\($0)" } ?? "transport"
        case .provider(let status, _, _): "http_\(status)"
        case .insufficientCredits: "insufficient_credits"
        case .invalidResponse: "invalid_response"
        case .emptyResponse: "empty_response"
        case .exhausted: "exhausted"
        }
    }

    var logDescription: String {
        switch self {
        case .nonHTTPResponse:
            return "non_http_response"
        case .timeout:
            return "timeout"
        case .transport(let code, let message):
            if let code { return "url_error=\(code) message=\(message)" }
            return "transport message=\(message)"
        case .provider(let status, let message, let retryAfterSeconds):
            let retryAfter = retryAfterSeconds.map { " retry_after_s=\($0)" } ?? ""
            let providerMessage = message.map { " message=\($0)" } ?? ""
            return "http_status=\(status)\(retryAfter)\(providerMessage)"
        case .insufficientCredits(let message):
            return "insufficient_credits message=\(message)"
        case .invalidResponse:
            return "invalid_response"
        case .emptyResponse:
            return "empty_response"
        case .exhausted(let failures):
            return failures.isEmpty
                ? "exhausted"
                : "exhausted failures=\(Self.failureSummary(failures))"
        }
    }

    /// Empty/HTML 5xx is a gateway failure; JSON 5xx already exhausted server retries.
    var isRetryableHostedFailure: Bool {
        switch self {
        case .provider(let status, let message, _):
            if status == 408 || status == 409 || status == 425 || status == 429 {
                return true
            }
            guard status >= 500 else { return false }
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
        case .timeout, .transport, .nonHTTPResponse, .invalidResponse, .emptyResponse:
            return true
        case .insufficientCredits, .exhausted:
            return false
        }
    }
}

enum LLMDiagnostics {
    static func description(_ error: Error) -> String {
        if let error = error as? LLMClientError {
            return error.logDescription
        }
        return String(describing: error)
    }

    static func userFacing(_ error: Error) -> String {
        let generic = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if let error = error as? LLMClientError {
            switch error {
            case .exhausted(let failures):
                detail = LLMClientError.failureSummary(failures)
            case .provider(let status, let message, _):
                let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail = message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
            case .transport(_, let message):
                detail = message
            case .insufficientCredits(let message):
                detail = message
            case .timeout, .nonHTTPResponse, .invalidResponse, .emptyResponse:
                detail = error.logDescription
            }
        } else {
            detail = description(error)
        }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(generic) != .orderedSame,
              !generic.localizedCaseInsensitiveContains(trimmed) else {
            return generic
        }
        return generic + "\n" + trimmed
    }

    static func preview(_ data: Data, limit: Int = 240) -> String {
        let raw = String(data: data.prefix(limit * 2), encoding: .utf8)
            ?? "binary_bytes=\(data.count)"
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
