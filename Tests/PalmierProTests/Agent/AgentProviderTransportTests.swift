import Foundation
import Testing
@testable import PalmierPro

@Suite("Configured agent transport", .serialized)
struct AgentProviderTransportTests {
    @Test func anthropicUsageUsesCumulativeOutputAndAllInputBuckets() {
        var usage = AnthropicUsageAccumulator()
        usage.update(["input_tokens": 100, "output_tokens": 1, "cache_creation_input_tokens": 20, "cache_read_input_tokens": 30], finalOutput: false)
        #expect(usage.finalUsage == nil)
        usage.update(["output_tokens": 10], finalOutput: true)
        usage.update(["input_tokens": 110, "output_tokens": 25], finalOutput: true)
        #expect(usage.finalUsage == .init(inputTokens: 160, outputTokens: 25))
        usage.update(["output_tokens": -1], finalOutput: true)
        #expect(usage.finalUsage == nil)
    }

    @Test func compatibleUsageOnlyChunkIsNotDiscarded() throws {
        var parser = OpenAICompatibleStreamParser()
        let events = try parser.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"completion_tokens_details":{"reasoning_tokens":15}}}"#)
        #expect(events == [.tokenUsage(.init(inputTokens: 100, outputTokens: 20))])
        #expect(try parser.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":100}}"#).isEmpty)
    }

    @Test func responsesTerminalUsageIncludesInvisibleOutputOnce() throws {
        var parser = OpenAIStreamParser()
        let events = try parser.consume(event: ["type": "response.completed", "response": [
            "status": "completed", "output": [], "usage": ["input_tokens": 120, "output_tokens": 80,
                "input_tokens_details": ["cached_tokens": 100], "output_tokens_details": ["reasoning_tokens": 60]]]])
        #expect(events == [.tokenUsage(.init(inputTokens: 120, outputTokens: 80)), .messageStop(stopReason: .endTurn)])
        #expect(AgentTokenUsage.from(["input_tokens": 10]) == nil)
        #expect(AgentTokenUsage.from(["input_tokens": -1, "output_tokens": 0]) == nil)
        var missing = OpenAIStreamParser()
        #expect(try missing.consume(event: ["type": "response.completed", "response": ["status": "completed"]]) == [.messageStop(stopReason: .endTurn)])
    }

    @Test func openAIEndpointsSeparateAgentFromTextCompletions() throws {
        for baseURL in [
            "https://api.openai.com/v1",
            "https://api.openai.com/v1/chat/completions/",
            "https://api.openai.com/v1/responses",
        ] {
            let profile = LLMProviderProfile(provider: .openAI, baseURL: baseURL, model: "gpt-5.6-luna")
            #expect(profile.agentProtocol == .openAIResponses)
            #expect(try profile.agentEndpoint().absoluteString == "https://api.openai.com/v1/responses")
            #expect(try profile.completionEndpoint().absoluteString == "https://api.openai.com/v1/chat/completions")
        }
    }

    @Test @MainActor func savedLegacyOpenRouterRemainsInAgentRoute() async throws {
        let suite = "AgentProviderTransportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let openAI = openAIProfile()
        let router = legacyOpenRouterProfile()
        let saved = LLMSettingsStore.PersistedConfiguration(
            providers: [openAI, router],
            routes: [.chat: LLMModelRoute(
                primaryModel: openAI.defaultModelReference!,
                fallbackModels: [router.defaultModelReference!],
                policy: .default(for: .chat)
            )]
        )
        defaults.set(try JSONEncoder().encode(saved), forKey: "voxella.llm.configuration.v2")
        let settings = LLMSettingsStore(defaults: defaults, legacyDefaults: [])
        try await settings.saveAPIKey("test-openai", providerID: openAI.id)
        try await settings.saveAPIKey("test-router", providerID: router.id)
        defer {
            try? KeychainStore.deleteProtected(account: openAI.credentialAccount)
            try? KeychainStore.deleteProtected(account: router.credentialAccount)
        }
        #expect(settings.hasUsableAgentModel)
        let route = try await settings.agentRuntimeRoute()
        #expect(route.configurations.map(\.agentProtocol) == [.openAIResponses, .openAICompatible])
        #expect(route.configurations.map(\.endpoint.path) == ["/v1/responses", "/api/v1/chat/completions"])
        #expect(settings.provider(id: router.id)?.provider == .openAICompatible)
    }

    @Test func responsesTranslateSavedOverridesAndKeepToolReasoning() throws {
        let body = OpenAIRequestBody.build(
            modelName: "gpt-5.6-luna", reasoningEffort: .medium,
            system: "Instructions", tools: [tool], messages: [userMessage],
            extraBody: [
                "reasoning_effort": .string("high"),
                "reasoning": .object(["summary": .string("concise")]),
                "max_tokens": .number(100),
                "max_completion_tokens": .number(2048),
                "thinking": .object(["type": .string("disabled")]),
            ]
        )
        #expect(body["reasoning"] as? [String: String] == ["effort": "high", "summary": "concise"])
        #expect(body["max_output_tokens"] as? Double == 2048)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["max_tokens"] == nil)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["thinking"] == nil)
        #expect(body["messages"] == nil)
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        let function = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(function["name"] as? String == "get_timeline")
        #expect(function["strict"] as? Bool == false)
    }

    @Test func responsesStreamCompletesToolRoundTripWithConfiguredModel() async throws {
        AgentTransportURLProtocol.state.reset([
            .init(status: 200, body: """
            data: {"type":"response.reasoning_summary_text.delta","delta":"Inspecting"}

            data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Inspecting"}],"encrypted_content":"opaque-test-reasoning"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"get_timeline","arguments":"{}"}}

            data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call"}]}}

            """),
            .init(status: 200, body: """
            data: {"type":"response.output_text.delta","delta":"Timeline verified"}

            data: {"type":"response.completed","response":{"status":"completed","output":[]}}

            """),
        ])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let client = try client(profiles: [openAIProfile()], session: session)
        let events = try await collect(client, messages: [userMessage])
        #expect(events.contains(.reasoningSummaryDelta("Inspecting", model: .luna)))
        #expect(events.contains(.reasoningComplete(
            itemID: "rs_1", summary: "Inspecting", encryptedContent: "opaque-test-reasoning", model: .luna
        )))
        #expect(events.contains(.toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}")))
        #expect(events.last == .messageStop(stopReason: .toolUse))
        let followup: [AgentRequestMessage] = [
            userMessage,
            .init(role: .assistant, content: [
                .content(.openAIReasoning(summary: "Inspecting", encryptedContent: "opaque-test-reasoning", itemID: "rs_1", model: .luna)),
                .content(.toolUse(id: "call_1", name: "get_timeline", inputJSON: "{}")),
            ]),
            .init(role: .user, content: [.content(.toolResult(toolUseId: "call_1", content: [.text("Timeline 1")], isError: false))]),
        ]
        let answer = try await collect(client, messages: followup)
        #expect(answer == [.textDelta("Timeline verified"), .messageStop(stopReason: .endTurn)])
        let requests = AgentTransportURLProtocol.state.requests
        #expect(requests.map(\.url?.path) == ["/v1/responses", "/v1/responses"])
        let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5.6-luna")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect(body["store"] as? Bool == false)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.contains { $0["encrypted_content"] as? String == "opaque-test-reasoning" })
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call_1" })
    }

    @Test func retryableFailureFallsBackToLegacyOpenRouter() async throws {
        AgentTransportURLProtocol.state.reset([
            .init(status: 503, body: #"{"error":{"message":"Unavailable"}}"#),
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"Fallback OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"),
        ])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let client = try client(profiles: [openAIProfile(), legacyOpenRouterProfile()], session: session)
        let events = try await collect(client, messages: [userMessage])
        #expect(events.contains(.textDelta("Fallback OK")))
        let requests = AgentTransportURLProtocol.state.requests
        #expect(requests.map(\.url?.path) == ["/v1/responses", "/api/v1/chat/completions"])
        let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "google/gemini-2.5-flash-lite")
        #expect(body["messages"] != nil)
        #expect(body["input"] == nil)
    }

    @Test func rejectedRequestPreservesReasonAndRedactsCredential() async throws {
        AgentTransportURLProtocol.state.reset([
            .init(status: 400, body: #"{"error":{"message":"Unsupported reasoning for test-openai"}}"#),
        ])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let client = try client(profiles: [openAIProfile()], session: session)
        do {
            _ = try await collect(client, messages: [userMessage])
            Issue.record("Expected the rejected request to throw")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 400"))
            #expect(error.localizedDescription.contains("Unsupported reasoning"))
            #expect(!error.localizedDescription.contains("test-openai"))
        }
    }

    @Test func retriesPrimaryBeforeFallback() async throws {
        AgentTransportURLProtocol.state.reset([
            .init(status: 503, body: "{}"), .init(status: 503, body: "{}"),
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"Fallback\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let client = try client(profiles: [openAIProfile(), legacyOpenRouterProfile()], session: session, maximumAttempts: 2)
        #expect(try await collect(client, messages: [userMessage]).contains(.textDelta("Fallback")))
        #expect(AgentTransportURLProtocol.state.requests.map(\.url?.path) == ["/v1/responses", "/v1/responses", "/api/v1/chat/completions"])
    }

    @Test func partialResponseFailureNeverSwitchesModel() async throws {
        AgentTransportURLProtocol.state.reset([.init(status: 200, body: """
        data: {"type":"response.output_text.delta","delta":"Partial answer"}

        data: {"type":"response.failed","response":{"status":"failed","error":{"message":"Interrupted"}}}

        """)])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let client = try client(profiles: [openAIProfile(), legacyOpenRouterProfile()], session: session, maximumAttempts: 2)
        var visible: [AgentStreamEvent] = []
        do {
            for try await event in client.stream(system: "Help", tools: [], messages: [userMessage], context: .init(
                conversationID: UUID(), traceID: UUID(), spanID: UUID(), inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil)) {
                visible.append(event)
            }
            Issue.record("Expected an interrupted response")
        } catch { #expect(visible.contains(.textDelta("Partial answer"))) }
        #expect(AgentTransportURLProtocol.state.requests.count == 1)
    }

    @Test func anthropicNativeStreamingPreservesThinkingAndTools() async throws {
        AgentTransportURLProtocol.state.reset([.init(status: 200, body: """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Inspect"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature"}}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool1","name":"get_timeline"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

        data: {"type":"message_stop"}

        """)])
        let profile = LLMProviderProfile(provider: .anthropic, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5")
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let events = try await collect(client(profiles: [profile], session: session), messages: [userMessage])
        #expect(events.contains(.thinkingDelta("Inspect")))
        #expect(events.contains(.thinkingSignature("signature")))
        #expect(events.contains(.toolUseComplete(id: "tool1", name: "get_timeline", inputJSON: "{}")))
        #expect(AgentTransportURLProtocol.state.requests.first?.value(forHTTPHeaderField: "x-api-key") == "test-openai")
        #expect(AgentTransportURLProtocol.state.requests.first?.url?.path == "/v1/messages")
    }

    @Test func routerConnectionChecksAuthenticatedKeyEndpoint() async throws {
        AgentTransportURLProtocol.state.reset([.init(status: 401, body: "{}")])
        let session = testSession()
        defer { session.invalidateAndCancel() }
        do {
            try await LLMProviderConnectivityTester(session: session).test(profile: legacyOpenRouterProfile(), apiKey: "rejected")
            Issue.record("Expected unauthorized key")
        } catch { #expect(error as? LLMProviderConnectionError == .unauthorized) }
        #expect(AgentTransportURLProtocol.state.requests.first?.url?.path == "/api/v1/key")
    }

    @Test func knowledgeResponsesUsesSelectedModelAndEffort() async throws {
        AgentTransportURLProtocol.state.reset([.init(status: 200, body: #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Knowledge answer"}]}]}"#)])
        let profile = openAIProfile()
        let session = testSession()
        defer { session.invalidateAndCancel() }
        let config = LLMRuntimeConfiguration(profile: profile, modelIdentifier: profile.defaultModelReference!, modelName: "gpt-6-sol",
            endpoint: try profile.completionEndpoint(), apiKey: "test-key", useCase: .chat, reasoningEffort: .high)
        let client = OpenAIResponsesTextClient(configuration: config, policy: .default(for: .chat), session: session)
        #expect(try await client.complete(system: "Use evidence", user: "Question") == "Knowledge answer")
        let request = try #require(AgentTransportURLProtocol.state.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(request.url?.path == "/v1/responses")
        #expect(body["stream"] as? Bool == false)
        #expect(body["model"] as? String == "gpt-6-sol")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
    }

    private var tool: AgentToolSchema {
        .init(name: "get_timeline", description: "Read the timeline", inputSchema: ["type": "object", "properties": [String: String]()])
    }
    private var userMessage: AgentRequestMessage {
        .init(role: .user, content: [.content(.text("Read the timeline without modifying it."))])
    }
    private func openAIProfile() -> LLMProviderProfile {
        .init(provider: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-5.6-luna")
    }
    private func legacyOpenRouterProfile() -> LLMProviderProfile {
        .init(provider: .openAICompatible, prefix: "openrouter", displayName: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "google/gemini-2.5-flash-lite")
    }
    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentTransportURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func client(profiles: [LLMProviderProfile], session: URLSession, maximumAttempts: Int = 1) throws -> ProviderAgentClient {
        ProviderAgentClient(route: LLMRuntimeRoute(
            useCase: .chat,
            configurations: try profiles.map { profile in
                LLMRuntimeConfiguration(profile: profile, modelIdentifier: profile.defaultModelReference!, modelName: profile.model,
                    endpoint: try profile.agentEndpoint(), apiKey: "test-openai", useCase: .chat, reasoningEffort: .medium)
            },
            policy: .init(timeoutSeconds: 60, maximumAttemptsPerModel: maximumAttempts, initialBackoffSeconds: 0)
        ), session: session)
    }
    private func collect(_ client: ProviderAgentClient, messages: [AgentRequestMessage]) async throws -> [AgentStreamEvent] {
        var result: [AgentStreamEvent] = []
        for try await event in client.stream(system: "Instructions", tools: [tool], messages: messages, context: .init(
            conversationID: UUID(), traceID: UUID(), spanID: UUID(), inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil
        )) { result.append(event) }
        return result
    }
}

private final class AgentTransportURLProtocol: URLProtocol {
    struct Reply { let status: Int; let body: String }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { recorded } }
        func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; recorded = [] } }
        func next(_ request: URLRequest) -> Reply {
            lock.withLock {
                recorded.append(request)
                return replies.isEmpty ? Reply(status: 500, body: "Unexpected request") : replies.removeFirst()
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let reply = Self.state.next(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
