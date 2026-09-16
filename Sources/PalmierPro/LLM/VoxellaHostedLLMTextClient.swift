import Foundation

struct VoxellaHostedLLMTextClient: LLMTextClient {
    typealias TokenProvider = @Sendable () async throws -> String
    typealias TokenRefresher = @Sendable () async throws -> Void

    let useCase: LLMUseCase
    let policy: LLMRequestPolicy
    let session: URLSession

    private let tokenProvider: TokenProvider
    private let tokenRefresher: TokenRefresher
    private let sleeper: ResilientLLMTextClient.Sleeper

    init(
        useCase: LLMUseCase,
        policy: LLMRequestPolicy? = nil,
        session: URLSession? = nil,
        tokenProvider: TokenProvider? = nil,
        tokenRefresher: TokenRefresher? = nil,
        sleeper: ResilientLLMTextClient.Sleeper? = nil
    ) {
        self.useCase = useCase
        let policy = policy ?? .default(for: useCase)
        self.policy = policy
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = policy.timeoutSeconds
            sessionConfiguration.timeoutIntervalForResource = policy.timeoutSeconds
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.httpMaximumConnectionsPerHost = OpenAICompatibleClient.maximumConnectionsPerHost
            self.session = URLSession(configuration: sessionConfiguration)
        }
        self.tokenProvider = tokenProvider ?? {
            try await VoxellaAuthService.shared.authorizedAccessToken()
        }
        self.tokenRefresher = tokenRefresher ?? {
            _ = try await VoxellaAuthService.shared.refreshAccessToken()
        }
        self.sleeper = sleeper ?? { try await Task.sleep(for: $0) }
    }

    func complete(system: String, user: String) async throws -> String {
        var shouldRefreshAccount = true
        defer {
            if shouldRefreshAccount {
                Task { @MainActor in
                    await AccountService.shared.refreshAccountForFeatureAccess()
                }
            }
        }
        let body: [String: Any] = [
            // Compatibility field only. The API chooses its env-configured model.
            "model": "voxella-hosted",
            "store": false,
            "stream": false,
            "instructions": system,
            "input": user,
        ]
        let attempts = max(1, policy.maximumAttemptsPerModel)
        let requestID = UUID().uuidString.lowercased()
        var lastError: Error?

        for attempt in 1...attempts {
            try Task.checkCancellation()
            let startedAt = Date()
            do {
                let data = try await send(body: body, requestID: requestID, retryingUnauthorized: true)
                guard let text = Self.outputText(from: data), !text.isEmpty else {
                    throw LLMClientError.emptyResponse
                }
                return text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let clientError = error as? LLMClientError,
                   case .insufficientCredits = clientError
                {
                    shouldRefreshAccount = false
                    await MainActor.run { HostedCreditAvailability.shared.markExhausted() }
                }
                lastError = error
                let elapsedMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                let retryable = Self.isRetryable(error)
                Log.llm.warning(
                    "hosted request failed use_case=\(useCase.rawValue) attempt=\(attempt) elapsed_ms=\(elapsedMilliseconds) retryable=\(retryable) detail=\(Self.failureDetail(error))"
                )
                guard retryable, attempt < attempts else { break }
                let delay = ResilientLLMTextClient.retryDelay(
                    error: error,
                    attempt: attempt,
                    initial: policy.initialBackoffSeconds
                )
                if delay > 0 {
                    try await sleeper(.seconds(delay))
                }
            }
        }
        throw lastError ?? LLMClientError.emptyResponse
    }

    private func send(
        body: [String: Any],
        requestID: String,
        retryingUnauthorized: Bool
    ) async throws -> Data {
        let token = try await tokenProvider()
        var request = URLRequest(url: VoxellaAPIConfiguration.apiURL("api/v1/llm/responses"))
        request.timeoutInterval = policy.timeoutSeconds
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(requestID, forHTTPHeaderField: "X-Client-Request-ID")
        request.setValue(useCase.rawValue, forHTTPHeaderField: "X-Voxella-LLM-Use-Case")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMClientError.nonHTTPResponse
            }
            if http.statusCode == 401, retryingUnauthorized {
                try await tokenRefresher()
                return try await send(body: body, requestID: requestID, retryingUnauthorized: false)
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 402 {
                    throw LLMClientError.insufficientCredits(
                        Self.providerErrorMessage(from: data)
                            ?? "You do not have enough credits for this AI request."
                    )
                }
                throw LLMClientError.provider(
                    status: http.statusCode,
                    message: Self.providerErrorMessage(from: data),
                    retryAfterSeconds: Self.retryAfterSeconds(from: http)
                )
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMClientError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw LLMClientError.timeout
        } catch let error as URLError {
            throw LLMClientError.transport(code: error.code.rawValue, message: error.localizedDescription)
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? LLMClientError else { return true }
        return error.isRetryableHostedFailure
    }

    private static func failureDetail(_ error: Error) -> String {
        if let error = error as? LLMClientError {
            return error.logDescription
        }
        return String(describing: error)
    }

    private static func outputText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let outputText = root["output_text"] as? String {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let output = root["output"] as? [[String: Any]] else { return nil }
        let text = output.flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = root["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String)
        }
        return root["message"] as? String
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, 30)
    }
}
