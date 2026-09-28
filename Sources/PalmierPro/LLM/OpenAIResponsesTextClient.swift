import Foundation

/// Knowledge answers use the same Responses protocol as the editing agent.
struct OpenAIResponsesTextClient: LLMConfigurableTextClient {
    let configuration: LLMRuntimeConfiguration
    let policy: LLMRequestPolicy
    var session: URLSession = .shared

    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, options: .default)
    }

    func complete(system: String, user: String, options: LLMTextCompletionOptions) async throws -> String {
        var request = URLRequest(url: try configuration.profile.agentEndpoint(), timeoutInterval: policy.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = OpenAIRequestBody.build(modelName: configuration.modelName,
            reasoningEffort: configuration.reasoningEffort ?? .medium, system: system,
            tools: [], messages: [.init(role: .user, content: [.content(.text(user))])],
            extraBody: configuration.profile.resolvedExtraBody)
        body["stream"] = false
        if configuration.chatCapability.thinking == .automatic { body.removeValue(forKey: "reasoning") }
        if let format = options.structuredOutput { body["text"] = ["format": format.responsesTextFormatValue] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled && Task.isCancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw LLMClientError.timeout }
        catch { throw LLMClientError.transport(code: nil, message: error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (root?["error"] as? [String: Any])?["message"] as? String
            throw LLMClientError.provider(status: http.statusCode,
                message: message?.replacingOccurrences(of: configuration.apiKey, with: "[redacted]"), retryAfterSeconds: nil)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["status"] as? String == "completed" else {
            throw LLMClientError.emptyResponse
        }
        let output = root["output"] as? [[String: Any]] ?? []
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMClientError.emptyResponse }
        return text
    }
}
