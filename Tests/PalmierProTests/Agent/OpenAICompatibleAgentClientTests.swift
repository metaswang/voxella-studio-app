import Foundation
import Testing
@testable import PalmierPro

private struct CapturedAgentRequest: Sendable {
    let url: URL?
    let authorization: String?
    let body: Data
}

private final class AgentRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CapturedAgentRequest] = []

    func append(_ request: URLRequest) {
        let captured = CapturedAgentRequest(
            url: request.url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: Self.readBody(from: request)
        )
        lock.withLock { requests.append(captured) }
    }

    var snapshot: [CapturedAgentRequest] {
        lock.withLock { requests }
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class AgentMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var handler: Handler?
    private static let lock = NSLock()

    static func install(_ value: @escaping Handler) {
        lock.withLock { handler = value }
    }

    static func uninstall() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let installed = Self.lock.withLock { Self.handler }
        guard let installed else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotLoadFromNetwork)
            )
            return
        }
        do {
            let (response, data) = try installed(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("OpenAI-compatible editing chat", .serialized)
struct OpenAICompatibleAgentClientTests {
    @Test
    func streamsTextAndToolCallsUsingTheConfiguredProvider() async throws {
        let requests = AgentRequestBox()
        AgentMockURLProtocol.install { request in
            requests.append(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            let body = """
            data: {"choices":[{"delta":{"content":"I’ll edit it."},"finish_reason":null}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"split_clip","arguments":"{\\"clip_id\\":"}}]},"finish_reason":null}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"abc\\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
            return (response, Data(body.utf8))
        }
        defer { AgentMockURLProtocol.uninstall() }

        let client = OpenAICompatibleAgentClient(
            route: runtimeRoute(configurations: [runtimeConfiguration(
                profile: .defaultMiniMax,
                modelIdentifier: "minimax/MiniMax-M3",
                modelName: "MiniMax-M3",
                host: "minimax.test"
            )]),
            sessionFactory: { _ in Self.mockSession() }
        )
        let tools = [
            AnthropicToolSchema(
                name: "split_clip",
                description: "Split a timeline clip.",
                inputSchema: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string"]],
                ]
            ),
        ]
        let messages = [
            AnthropicMessage(
                role: .user,
                content: [["type": "text", "text": "Split clip abc."]]
            ),
        ]

        var text = ""
        var toolCall: (id: String, name: String, input: String)?
        var stoppedForToolUse = false
        for try await event in client.stream(
            system: "You edit videos.",
            tools: tools,
            messages: messages
        ) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .toolUseComplete(let id, let name, let input):
                toolCall = (id, name, input)
            case .messageStop(let reason):
                if case .toolUse = reason { stoppedForToolUse = true }
            }
        }

        #expect(text == "I’ll edit it.")
        #expect(toolCall?.id == "call_1")
        #expect(toolCall?.name == "split_clip")
        #expect(toolCall?.input == #"{"clip_id":"abc"}"#)
        #expect(stoppedForToolUse)

        let request = try #require(requests.snapshot.first)
        #expect(request.authorization == "Bearer test-key")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(payload["model"] as? String == "MiniMax-M3")
        #expect(payload["stream"] as? Bool == true)
        #expect(payload["reasoning_split"] as? Bool == true)
        #expect((payload["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(payload["reasoning_effort"] == nil)
        #expect((payload["tools"] as? [[String: Any]])?.count == 1)
        #expect((payload["messages"] as? [[String: Any]])?.count == 2)
    }

    @Test
    func fallsBackOnlyBeforeAnyStreamEventIsEmitted() async throws {
        let requests = AgentRequestBox()
        AgentMockURLProtocol.install { request in
            requests.append(request)
            let isPrimary = request.url?.host == "primary.test"
            let status = isPrimary ? 503 : 200
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": isPrimary ? "application/json" : "text/event-stream"]
            ))
            if isPrimary {
                return (response, Data(#"{"error":{"message":"temporarily unavailable"}}"#.utf8))
            }
            return (
                response,
                Data("""
                data: {"choices":[{"delta":{"content":"Recovered."},"finish_reason":"stop"}]}

                data: [DONE]

                """.utf8)
            )
        }
        defer { AgentMockURLProtocol.uninstall() }

        let client = OpenAICompatibleAgentClient(
            route: runtimeRoute(configurations: [
                runtimeConfiguration(
                    profile: .defaultOpenAI,
                    modelIdentifier: "openai/gpt-5.4-nano",
                    modelName: "gpt-5.4-nano",
                    host: "primary.test"
                ),
                runtimeConfiguration(
                    profile: .defaultMiniMax,
                    modelIdentifier: "minimax/MiniMax-M3",
                    modelName: "MiniMax-M3",
                    host: "fallback.test"
                ),
            ]),
            sessionFactory: { _ in Self.mockSession() },
            sleeper: { _ in }
        )

        var text = ""
        for try await event in client.stream(system: "Edit.", tools: [], messages: []) {
            if case .textDelta(let delta) = event { text += delta }
        }

        #expect(text == "Recovered.")
        #expect(requests.snapshot.map(\.url?.host) == ["primary.test", "fallback.test"])
    }

    @Test
    func removesReasoningTagsSplitAcrossStreamChunks() async throws {
        AgentMockURLProtocol.install { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (
                response,
                Data("""
                data: {"choices":[{"delta":{"content":"<thi"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"nk>private reasoning"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"</th"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"ink>\\nVisible answer."},"finish_reason":"stop"}]}

                data: [DONE]

                """.utf8)
            )
        }
        defer { AgentMockURLProtocol.uninstall() }

        let client = OpenAICompatibleAgentClient(
            route: runtimeRoute(configurations: [runtimeConfiguration(
                profile: .defaultMiniMax,
                modelIdentifier: "minimax/MiniMax-M3",
                modelName: "MiniMax-M3",
                host: "minimax.test"
            )]),
            sessionFactory: { _ in Self.mockSession() }
        )

        var text = ""
        for try await event in client.stream(system: "Edit.", tools: [], messages: []) {
            if case .textDelta(let delta) = event { text += delta }
        }

        #expect(text == "Visible answer.")
    }

    @Test
    func removesStandaloneMiniMaxClosingReasoningTagBeforeToolCall() async throws {
        AgentMockURLProtocol.install { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (
                response,
                Data("""
                data: {"choices":[{"delta":{"reasoning_content":"private reasoning"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"</thi"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"nk>\\n","tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_timeline","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """.utf8)
            )
        }
        defer { AgentMockURLProtocol.uninstall() }

        let client = OpenAICompatibleAgentClient(
            route: runtimeRoute(configurations: [runtimeConfiguration(
                profile: .defaultMiniMax,
                modelIdentifier: "minimax/MiniMax-M3",
                modelName: "MiniMax-M3",
                host: "minimax.test"
            )]),
            sessionFactory: { _ in Self.mockSession() }
        )

        var text = ""
        var toolName: String?
        for try await event in client.stream(system: "Edit.", tools: [], messages: []) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .toolUseComplete(_, let name, _):
                toolName = name
            case .messageStop:
                break
            }
        }

        #expect(text.isEmpty)
        #expect(toolName == "get_timeline")
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func runtimeConfiguration(
        profile: LLMProviderProfile,
        modelIdentifier: String,
        modelName: String,
        host: String
    ) -> LLMRuntimeConfiguration {
        LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: modelIdentifier,
            modelName: modelName,
            endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
            apiKey: "test-key"
        )
    }

    private func runtimeRoute(
        configurations: [LLMRuntimeConfiguration]
    ) -> LLMRuntimeRoute {
        LLMRuntimeRoute(
            useCase: .chat,
            configurations: configurations,
            policy: LLMRequestPolicy(
                timeoutSeconds: 30,
                maximumAttemptsPerModel: 1,
                initialBackoffSeconds: 0
            )
        )
    }
}
