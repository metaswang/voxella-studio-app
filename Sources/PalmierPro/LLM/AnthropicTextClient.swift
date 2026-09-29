import Foundation

/// Text-only Anthropic transport for non-agent consumers of the shared
/// `AI editing chat` route (for example knowledge answers and dub rewrite).
struct AnthropicTextClient: LLMConfigurableTextClient {
    let configuration: LLMRuntimeConfiguration
    let policy: LLMRequestPolicy
    let session: URLSession

    init(configuration: LLMRuntimeConfiguration, policy: LLMRequestPolicy) {
        self.configuration = configuration
        self.policy = policy
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = policy.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = policy.timeoutSeconds
        sessionConfiguration.waitsForConnectivity = false
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, options: .default)
    }

    func complete(
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: policy.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": configuration.modelName,
            "max_tokens": 8_192,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        if configuration.useCase == .chat {
            configuration.chatCapability.applyAnthropic(to: &body, effort: configuration.reasoningEffort)
        }
        for (key, value) in foundationJSON(configuration.profile.resolvedExtraBody) { body[key] = value }
        if let format = options.structuredOutput {
            var output = body["output_config"] as? [String: Any] ?? [:]
            output["format"] = ["type": "json_schema", "schema": foundationJSON(format.schema)]
            body["output_config"] = output
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw LLMClientError.timeout
        } catch let error as URLError {
            throw LLMClientError.transport(code: error.code.rawValue, message: error.localizedDescription)
        } catch {
            throw LLMClientError.transport(code: nil, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.provider(
                status: http.statusCode,
                message: providerErrorMessage(data)?.replacingOccurrences(of: configuration.apiKey, with: "[redacted]"),
                retryAfterSeconds: nil
            )
        }
        guard let responseBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (responseBody["content"] as? [[String: Any]])?
                .compactMap({ $0["type"] as? String == "text" ? $0["text"] as? String : nil })
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return text
    }

    private func providerErrorMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = root["error"] as? [String: Any] { return error["message"] as? String }
        return root["message"] as? String
    }
}

private func foundationJSON(_ object: [String: LLMJSONValue]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: object.map { ($0.key, foundationJSON($0.value)) })
}

private func foundationJSON(_ value: LLMJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): foundationJSON(value)
    case .array(let value): value.map(foundationJSON)
    case .null: NSNull()
    }
}
