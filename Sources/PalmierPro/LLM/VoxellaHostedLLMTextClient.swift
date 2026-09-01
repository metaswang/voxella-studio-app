import Foundation

struct VoxellaHostedLLMTextClient: LLMTextClient {
    let useCase: LLMUseCase
    let session: URLSession

    init(useCase: LLMUseCase, session: URLSession = .shared) {
        self.useCase = useCase
        self.session = session
    }

    func complete(system: String, user: String) async throws -> String {
        defer {
            Task { @MainActor in
                await AccountService.shared.refreshAccountForFeatureAccess()
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
        let requestID = UUID().uuidString.lowercased()
        let data = try await send(body: body, requestID: requestID, retryingUnauthorized: true)
        guard let text = Self.outputText(from: data), !text.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return text
    }

    private func send(
        body: [String: Any],
        requestID: String,
        retryingUnauthorized: Bool
    ) async throws -> Data {
        let token = try await VoxellaAuthService.shared.authorizedAccessToken()
        var request = URLRequest(url: VoxellaAPIConfiguration.apiURL("api/v1/llm/responses"))
        request.timeoutInterval = LLMRequestPolicy.default(for: useCase).timeoutSeconds
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
                _ = try await VoxellaAuthService.shared.refreshAccessToken()
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
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw LLMClientError.timeout
        } catch let error as URLError {
            throw LLMClientError.transport(code: error.code.rawValue, message: error.localizedDescription)
        }
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
