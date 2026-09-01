import Foundation

struct HostedAgentClient: AgentClient {
    let settings: AgentRunSettings

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            try await run(
                system: system,
                tools: tools,
                messages: messages,
                context: context,
                continuation: continuation,
                retryingUnauthorized: true
            )
        }
    }

    private func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        retryingUnauthorized: Bool
    ) async throws {
        defer {
            Task { @MainActor in
                await AccountService.shared.refreshAccountForFeatureAccess()
            }
        }
        let token = try await VoxellaAuthService.shared.authorizedAccessToken()
        var request = URLRequest(url: VoxellaAPIConfiguration.apiURL("api/v1/llm/responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(context.outputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Client-Request-ID")
        context.apply(to: &request, telemetryEnabled: true)
        var body = OpenAIRequestBody.build(
                // The server owns the actual model. This is a compatibility
                // value and is intentionally not exposed by the hosted UI.
                model: .terra,
                reasoningEffort: settings.reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        body["model"] = "voxella-hosted"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )

        do {
            let bytes = try await AgentHTTP.bytes(for: request) { status, body in
                AgentClientTransportError.httpError(provider: .openAI, status: status, body: body)
            }
            try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
        } catch let error as AgentClientTransportError {
            if case .httpError(_, let status, _) = error, status == 401, retryingUnauthorized {
                _ = try await VoxellaAuthService.shared.refreshAccessToken()
                try await run(
                    system: system,
                    tools: tools,
                    messages: messages,
                    context: context,
                    continuation: continuation,
                    retryingUnauthorized: false
                )
                return
            }
            if case .httpError(_, let status, let body) = error, status == 402 {
                throw AgentClientTransportError.insufficientCredits(body)
            }
            throw error
        }
    }
}
