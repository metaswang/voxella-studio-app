import Foundation
import Testing
@testable import PalmierPro

private enum RoutedStubOutcome: Sendable {
    case success(String)
    case failure(LLMClientError)
    case cancelled
}

private actor RoutedStubState {
    private var outcomes: [String: [RoutedStubOutcome]]
    private var attempts: [String: Int] = [:]

    init(outcomes: [String: [RoutedStubOutcome]]) {
        self.outcomes = outcomes
    }

    func complete(model: String) throws -> String {
        attempts[model, default: 0] += 1
        guard var queue = outcomes[model], !queue.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        let outcome = queue.removeFirst()
        outcomes[model] = queue
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    func attemptCount(for model: String) -> Int {
        attempts[model, default: 0]
    }
}

private actor CredentialWriteRecorder {
    private var values: [UUID: String] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: String, providerID: UUID) {
        values[providerID] = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitForWrite() async {
        guard values.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func value(for providerID: UUID) -> String? {
        values[providerID]
    }
}

private struct RoutedStubClient: LLMTextClient {
    let model: String
    let state: RoutedStubState

    func complete(system: String, user: String) async throws -> String {
        try await state.complete(model: model)
    }
}

@Suite("LLM routing and resilience")
struct LLMResilienceTests {
    @Test @MainActor
    func defaultRoutesUseSceneSpecificProviderPrefixedModels() throws {
        let suiteName = "LLMResilienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = LLMSettingsStore(defaults: defaults)

        #expect(settings.route(for: .translation).primaryModel == "openai/gpt-5.4-nano")
        #expect(settings.route(for: .subtitleProcessing).primaryModel == "openai/gpt-5.6-luna")
        #expect(settings.route(for: .chat).primaryModel == "minimax/MiniMax-M3")
        #expect(Set(settings.providers.map(\.normalizedPrefix)) == ["openai", "minimax"])
    }

    @Test @MainActor
    func legacyDefaultsDomainMigratesIntoStableApplicationDomain() throws {
        let currentSuiteName = "LLMStableDefaultsTests.\(UUID().uuidString)"
        let legacySuiteName = "LLMLegacyDefaultsTests.\(UUID().uuidString)"
        let currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
        defer {
            currentDefaults.removePersistentDomain(forName: currentSuiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }

        let profile = LLMProviderProfile(
            provider: .openAICompatible,
            prefix: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash"
        )
        let saved = LLMSettingsStore.PersistedConfiguration(
            providers: [profile],
            routes: [.chat: .default(for: .chat)]
        )
        legacyDefaults.set(
            try JSONEncoder().encode(saved),
            forKey: "voxella.llm.configuration.v2"
        )

        let settings = LLMSettingsStore(
            defaults: currentDefaults,
            legacyDefaults: [legacyDefaults]
        )

        #expect(settings.providers == [profile])
        #expect(currentDefaults.data(forKey: "voxella.llm.configuration.v2") != nil)
    }

    @Test @MainActor
    func malformedConfigurationIsNotReplacedByDefaults() throws {
        let suiteName = "LLMMalformedDefaultsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformed = Data("not-json".utf8)
        defaults.set(malformed, forKey: "voxella.llm.configuration.v2")

        let settings = LLMSettingsStore(defaults: defaults, legacyDefaults: [])

        #expect(settings.configurationError != nil)
        #expect(defaults.data(forKey: "voxella.llm.configuration.v2") == malformed)
    }

    @Test @MainActor
    func legacySubtitleMigrationRunsOnlyOnce() throws {
        let suiteName = "LLMSubtitleMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = LLMSettingsStore(defaults: defaults, legacyDefaults: [])
        let legacyRoute = LLMModelRoute(
            primaryModel: "openai/gpt-5.4-nano",
            fallbackModels: ["minimax/MiniMax-M3"],
            policy: .default(for: .subtitleProcessing)
        )
        try settings.updateRoute(legacyRoute, for: .subtitleProcessing)

        let reloaded = LLMSettingsStore(defaults: defaults, legacyDefaults: [])

        #expect(reloaded.route(for: .subtitleProcessing) == legacyRoute)
    }

    @Test @MainActor
    func flushingPendingAPIKeySaveDoesNotDependOnSettingsPaneLifetime() async throws {
        let suiteName = "LLMCredentialFlushTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = CredentialWriteRecorder()
        let settings = LLMSettingsStore(
            defaults: defaults,
            legacyDefaults: [],
            credentialSaver: { value, profile in
                await recorder.record(value, providerID: profile.id)
            }
        )
        let providerID = try #require(settings.providers.first?.id)

        settings.scheduleAPIKeySave("temporary-test-key", providerID: providerID)
        settings.flushAPIKeySave(for: providerID)
        await recorder.waitForWrite()

        #expect(await recorder.value(for: providerID) == "temporary-test-key")
    }

    @Test @MainActor
    func completedAPIKeySaveReportsSavedState() async throws {
        let suiteName = "LLMCredentialStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LLMSettingsStore(
            defaults: defaults,
            legacyDefaults: [],
            credentialSaver: { _, _ in }
        )
        let providerID = try #require(settings.providers.first?.id)

        try await settings.saveAPIKey("saved-test-key", providerID: providerID)

        #expect(settings.apiKeySaveState(for: providerID) == .saved)
        #expect(settings.hasAPIKey(for: providerID))
    }

    @Test
    func credentialAccountRemainsStableWhenProviderEndpointChanges() {
        var profile = LLMProviderProfile(
            provider: .openAICompatible,
            prefix: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash"
        )
        let account = profile.credentialAccount

        profile.baseURL = "https://api.deepseek.com/v1"

        #expect(profile.credentialAccount == account)
        #expect(profile.legacyCredentialAccount != account)
    }

    @Test
    func miniMaxM3DisablesThinkingAndSeparatesLegacyReasoning() {
        let configuration = LLMRuntimeConfiguration(
            profile: .defaultMiniMax,
            modelIdentifier: "minimax/MiniMax-M3",
            modelName: "MiniMax-M3",
            endpoint: URL(string: "https://api.minimax.io/v1/chat/completions")!,
            apiKey: "test-minimax"
        )

        #expect(configuration.openAICompatibleRequestOptions == .init(
            reasoningSplit: true,
            thinkingType: "disabled"
        ))
    }

    @Test
    func miniMaxM2KeepsThinkingSeparatedBecauseItCannotBeDisabled() {
        var profile = LLMProviderProfile.defaultMiniMax
        profile.model = "MiniMax-M2.7"
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "minimax/MiniMax-M2.7",
            modelName: "MiniMax-M2.7",
            endpoint: URL(string: "https://api.minimax.io/v1/chat/completions")!,
            apiKey: "test-minimax"
        )

        #expect(configuration.openAICompatibleRequestOptions == .init(
            reasoningSplit: true,
            thinkingType: nil
        ))
    }

    @Test
    func deepSeekV4FlashDisablesDefaultThinkingMode() {
        let profile = LLMProviderProfile(
            provider: .openAICompatible,
            prefix: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash"
        )
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "deepseek/deepseek-v4-flash",
            modelName: "deepseek-v4-flash",
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            apiKey: "test-deepseek"
        )

        #expect(configuration.openAICompatibleRequestOptions == .init(
            thinkingType: "disabled"
        ))
    }

    @Test
    func deepSeekHostDetectionDisablesThinkingWithoutDeepSeekPrefix() {
        let profile = LLMProviderProfile(
            provider: .openAICompatible,
            prefix: "provider",
            displayName: "Custom DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro"
        )
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "provider/deepseek-v4-pro",
            modelName: "deepseek-v4-pro",
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            apiKey: "test-deepseek"
        )

        #expect(configuration.openAICompatibleRequestOptions == .init(
            thinkingType: "disabled"
        ))
    }

    @Test @MainActor
    func legacySingleProviderMigratesIntoMultiProviderRoutes() throws {
        let suiteName = "LLMLegacyMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyJSON = """
        {
          "provider": "openAICompatible",
          "baseURL": "https://api.minimax.io/v1",
          "model": "MiniMax-M3"
        }
        """
        defaults.set(
            try #require(legacyJSON.data(using: .utf8)),
            forKey: "voxella.llm.provider-profile.v1"
        )

        let settings = LLMSettingsStore(defaults: defaults)

        #expect(settings.providers.contains { $0.normalizedPrefix == "minimax" })
        #expect(settings.providers.contains { $0.normalizedPrefix == "openai" })
        #expect(
            settings.route(for: .subtitleProcessing).modelChain.contains("minimax/MiniMax-M3")
        )
    }

    @Test
    func timeoutRetriesPrimaryThenFallsBackToNextProvider() async throws {
        let state = RoutedStubState(outcomes: [
            "openai/gpt-5.4-nano": [
                .failure(.timeout),
                .failure(.timeout),
            ],
            "minimax/MiniMax-M3": [
                .success("fallback result"),
            ],
        ])
        let client = ResilientLLMTextClient(
            route: route(maximumAttempts: 2),
            clientFactory: { configuration, _ in
                RoutedStubClient(model: configuration.modelIdentifier, state: state)
            },
            sleeper: { _ in }
        )

        let result = try await client.complete(system: "system", user: "user")

        #expect(result == "fallback result")
        #expect(await state.attemptCount(for: "openai/gpt-5.4-nano") == 2)
        #expect(await state.attemptCount(for: "minimax/MiniMax-M3") == 1)
    }

    @Test
    func authenticationFailureSkipsSameModelRetryAndUsesFallback() async throws {
        let state = RoutedStubState(outcomes: [
            "openai/gpt-5.4-nano": [
                .failure(.provider(
                    status: 401,
                    message: "invalid key",
                    retryAfterSeconds: nil
                )),
            ],
            "minimax/MiniMax-M3": [
                .success("fallback result"),
            ],
        ])
        let client = ResilientLLMTextClient(
            route: route(maximumAttempts: 3),
            clientFactory: { configuration, _ in
                RoutedStubClient(model: configuration.modelIdentifier, state: state)
            },
            sleeper: { _ in }
        )

        let result = try await client.complete(system: "system", user: "user")

        #expect(result == "fallback result")
        #expect(await state.attemptCount(for: "openai/gpt-5.4-nano") == 1)
        #expect(await state.attemptCount(for: "minimax/MiniMax-M3") == 1)
    }

    @Test
    func cancellationNeverRetriesOrFallsBack() async {
        let state = RoutedStubState(outcomes: [
            "openai/gpt-5.4-nano": [.cancelled],
            "minimax/MiniMax-M3": [.success("must not run")],
        ])
        let client = ResilientLLMTextClient(
            route: route(maximumAttempts: 3),
            clientFactory: { configuration, _ in
                RoutedStubClient(model: configuration.modelIdentifier, state: state)
            },
            sleeper: { _ in }
        )

        await #expect(throws: CancellationError.self) {
            try await client.complete(system: "system", user: "user")
        }
        #expect(await state.attemptCount(for: "openai/gpt-5.4-nano") == 1)
        #expect(await state.attemptCount(for: "minimax/MiniMax-M3") == 0)
    }

    private func route(maximumAttempts: Int) -> LLMRuntimeRoute {
        let openAI = LLMProviderProfile.defaultOpenAI
        let miniMax = LLMProviderProfile.defaultMiniMax
        return LLMRuntimeRoute(
            useCase: .subtitleProcessing,
            configurations: [
                LLMRuntimeConfiguration(
                    profile: openAI,
                    modelIdentifier: "openai/gpt-5.4-nano",
                    modelName: "gpt-5.4-nano",
                    endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                    apiKey: "test-openai"
                ),
                LLMRuntimeConfiguration(
                    profile: miniMax,
                    modelIdentifier: "minimax/MiniMax-M3",
                    modelName: "MiniMax-M3",
                    endpoint: URL(string: "https://api.minimax.io/v1/chat/completions")!,
                    apiKey: "test-minimax"
                ),
            ],
            policy: LLMRequestPolicy(
                timeoutSeconds: 600,
                maximumAttemptsPerModel: maximumAttempts,
                initialBackoffSeconds: 0
            )
        )
    }
}
