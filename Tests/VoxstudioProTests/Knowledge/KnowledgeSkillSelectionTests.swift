import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Knowledge skill selection")
struct KnowledgeSkillSelectionTests {
    @Test
    func usesBoundedDedicatedPolicy() {
        let route = LLMModelRoute.default(for: .skillSelection)

        #expect(route.primaryModel == "openai/gpt-5.4-nano")
        #expect(route.fallbackModels.isEmpty)
        #expect(route.policy.timeoutSeconds == 8)
        #expect(route.policy.maximumAttemptsPerModel == 1)
        #expect(route.policy.initialBackoffSeconds == 0)
        #expect(LLMRequestPolicy.minimumTimeoutSeconds(for: .skillSelection) == 3)
    }

    @Test
    func nativePromptDisclosesMethodsProgressively() {
        let skill = Skill(id: "method", name: "Method", description: "Read then verify",
                          path: URL(fileURLWithPath: "/tmp/method/SKILL.md"))
        let prompt = KnowledgeAgentRuntime.systemPrompt(skills: [skill])
        #expect(prompt.contains("read_skill"))
        #expect(prompt.contains("method: Read then verify"))
        #expect(!prompt.contains("selected_skill_ids"))
        #expect(!prompt.contains("Think step-by-step"))
    }

    @Test
    func byokSelectorRequestDisablesReasoningAndCapsOutput() {
        let configuration = LLMRuntimeConfiguration(
            profile: .defaultOpenAI,
            modelIdentifier: "openai/gpt-5.4-nano",
            modelName: "gpt-5.4-nano",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: "test-key",
            useCase: .skillSelection
        )

        let body = configuration.resolvedExtraBody

        #expect(body["max_completion_tokens"] == .number(256))
        #expect(body["max_tokens"] == nil)
        #expect(body["reasoning_effort"] == .string("minimal"))
        #expect(body["reasoning"] == nil)
        #expect(body["temperature"] == nil)
    }
}

@Suite("Hosted skill selection request", .serialized)
struct HostedSkillSelectionRequestTests {
    @Test
    func sendsResponsesSchemaAndLatencyControls() async throws {
        HostedSkillSelectionURLProtocol.state.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HostedSkillSelectionURLProtocol.self]
        let client = VoxellaHostedLLMTextClient(
            useCase: .skillSelection,
            policy: .default(for: .skillSelection),
            session: URLSession(configuration: sessionConfiguration),
            tokenProvider: { "test-token" },
            tokenRefresher: {},
            sleeper: { _ in }
        )

        let response = try await client.complete(
            system: "system",
            user: "user",
            options: .skillSelection
        )

        #expect(response == #"{"selected_skill_ids":[]}"#)
        let body = try #require(HostedSkillSelectionURLProtocol.state.body())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_output_tokens"] as? Int == 256)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "minimal")
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "skill_selection")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(
            HostedSkillSelectionURLProtocol.state.header("X-Voxella-LLM-Use-Case")
                == "skillSelection"
        )
    }

    @Test
    func dedicatedPolicyDoesNotRetryProviderFailure() async {
        HostedSkillSelectionURLProtocol.state.reset(statusCode: 500)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HostedSkillSelectionURLProtocol.self]
        let client = VoxellaHostedLLMTextClient(
            useCase: .skillSelection,
            policy: .default(for: .skillSelection),
            session: URLSession(configuration: sessionConfiguration),
            tokenProvider: { "test-token" },
            tokenRefresher: {},
            sleeper: { _ in }
        )

        await #expect(throws: LLMClientError.self) {
            try await client.complete(system: "system", user: "user", options: .skillSelection)
        }
        #expect(HostedSkillSelectionURLProtocol.state.requestCount() == 1)
    }
}

private final class HostedSkillSelectionRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBody: Data?
    private var latestHeaders: [String: String] = [:]
    private var statusCode = 200
    private var count = 0

    func reset(statusCode: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        latestBody = nil
        latestHeaders = [:]
        self.statusCode = statusCode
        count = 0
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        latestBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        latestHeaders = request.allHTTPHeaderFields ?? [:]
        count += 1
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }

    func body() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return latestBody
    }

    func header(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latestHeaders[name]
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func response() -> (statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        let body = statusCode == 200
            ? Data(#"{"output_text":"{\"selected_skill_ids\":[]}"}"#.utf8)
            : Data(#"{"error":{"message":"provider unavailable"}}"#.utf8)
        return (statusCode, body)
    }
}

private final class HostedSkillSelectionURLProtocol: URLProtocol {
    static let state = HostedSkillSelectionRequestState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        let responseData = Self.state.response()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseData.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
