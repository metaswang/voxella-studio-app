import Foundation
import Testing
@testable import PalmierPro

@Suite("LLM request overrides", .serialized)
struct LLMRequestOverridesTests {
    @Test
    func parsesOnlyJSONObjects() throws {
        let object = try LLMJSONValue.parseObject(#"{"temperature":0.2,"stream":false}"#)

        #expect(object["temperature"] == .number(0.2))
        #expect(object["stream"] == .bool(false))
        #expect(throws: LLMRequestOverridesError.self) {
            try LLMJSONValue.parseObject("[1, 2, 3]")
        }
    }

    @Test
    func openRouterRoutingDeepMergesWithCustomBody() throws {
        var profile = LLMProviderProfile(
            provider: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            model: "z-ai/glm-5.3-flash"
        )
        profile.openRouterRouting = LLMOpenRouterRouting(
            enabled: true,
            order: ["Baseten", "Z.AI"],
            allowFallbacks: true,
            sort: .throughput
        )
        profile.extraBody = [
            "provider": .object([
                "order": .array([.string("Custom endpoint")]),
                "zdr": .bool(true),
            ]),
            "thinking": .object(["type": .string("enabled")]),
        ]

        let resolved = profile.resolvedExtraBody
        guard case .object(let provider)? = resolved["provider"] else {
            Issue.record("Expected provider routing object")
            return
        }

        #expect(provider["order"] == .array([.string("Custom endpoint")]))
        #expect(provider["allow_fallbacks"] == .bool(true))
        #expect(provider["sort"] == nil)
        #expect(provider["zdr"] == .bool(true))
        #expect(resolved["thinking"] == .object(["type": .string("enabled")]))
    }

    @Test
    func clientSendsResolvedExtraBodyAtRequestRoot() async throws {
        var profile = LLMProviderProfile(
            provider: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            model: "z-ai/glm-5.3-flash"
        )
        profile.openRouterRouting = LLMOpenRouterRouting(
            enabled: true,
            order: ["Baseten", "Z.AI"],
            allowFallbacks: false,
            sort: nil
        )
        profile.extraBody = ["temperature": .number(0.2)]
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "openrouter/z-ai/glm-5.3-flash",
            modelName: "z-ai/glm-5.3-flash",
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            apiKey: "test-key"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturingLLMURLProtocol.self]
        let client = OpenAICompatibleClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )

        #expect(try await client.complete(system: "system", user: "user") == "ok")
        let body = try #require(CapturingLLMURLProtocol.recorder.body())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let provider = try #require(json["provider"] as? [String: Any])

        #expect(json["model"] as? String == "z-ai/glm-5.3-flash")
        #expect(json["temperature"] as? Double == 0.2)
        #expect(provider["order"] as? [String] == ["Baseten", "Z.AI"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
    }

    @Test
    func subtitleClientDisablesReasoningInsteadOfLoweringEffort() async throws {
        let profile = LLMProviderProfile(
            provider: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            model: "google/gemini-2.5-flash-lite"
        )
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "openrouter/google/gemini-2.5-flash-lite",
            modelName: "google/gemini-2.5-flash-lite",
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            apiKey: "test-key",
            useCase: .subtitleProcessing
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturingLLMURLProtocol.self]
        let client = OpenAICompatibleClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )

        #expect(try await client.complete(system: "system", user: "user") == "ok")
        let body = try #require(CapturingLLMURLProtocol.recorder.body())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(json["reasoning"] as? [String: Any])

        #expect(reasoning["enabled"] as? Bool == false)
        #expect(reasoning["effort"] == nil)
        #expect(json["temperature"] as? Double == 0)
        #expect(json["max_tokens"] as? Int == 4_096 || json["max_tokens"] as? Double == 4_096)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "disabled")
    }
}

private final class LLMRequestBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBody: Data?

    func record(_ body: Data?) {
        lock.lock()
        defer { lock.unlock() }
        latestBody = body
    }

    func body() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return latestBody
    }
}

private final class CapturingLLMURLProtocol: URLProtocol {
    static let recorder = LLMRequestBodyRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? readBodyStream()
        Self.recorder.record(body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBodyStream() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
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
}
