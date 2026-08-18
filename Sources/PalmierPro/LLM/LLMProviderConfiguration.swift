import CryptoKit
import Foundation
import Observation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case miniMax
    case deepInfra
    case zAI
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .miniMax: "MiniMax"
        case .deepInfra: "DeepInfra"
        case .zAI: "Z.AI"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    var defaultPrefix: String {
        switch self {
        case .openAI: "openai"
        case .miniMax: "minimax"
        case .deepInfra: "deepinfra"
        case .zAI: "zai"
        case .openAICompatible: "provider"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .miniMax: "https://api.minimax.io/v1"
        case .deepInfra: "https://api.deepinfra.com/v1/openai"
        case .zAI: "https://api.z.ai/api/paas/v4"
        case .openAICompatible: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.4-nano"
        case .miniMax: "MiniMax-M3"
        case .deepInfra, .zAI, .openAICompatible: ""
        }
    }
}

struct LLMProviderProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: LLMProviderKind
    var prefix: String
    var displayName: String
    var baseURL: String
    var model: String

    static let defaultOpenAI = LLMProviderProfile(
        id: UUID(uuidString: "52C91A63-4B4F-4F10-A4F4-68E00D3A2D01")!,
        provider: .openAI,
        prefix: "openai",
        displayName: "OpenAI",
        baseURL: LLMProviderKind.openAI.defaultBaseURL,
        model: LLMProviderKind.openAI.defaultModel
    )

    static let defaultMiniMax = LLMProviderProfile(
        id: UUID(uuidString: "4BBF72B2-FC92-4AD2-B26D-221736865A71")!,
        provider: .miniMax,
        prefix: "minimax",
        displayName: "MiniMax",
        baseURL: LLMProviderKind.miniMax.defaultBaseURL,
        model: LLMProviderKind.miniMax.defaultModel
    )

    init(
        id: UUID = UUID(),
        provider: LLMProviderKind,
        prefix: String? = nil,
        displayName: String? = nil,
        baseURL: String,
        model: String
    ) {
        self.id = id
        self.provider = provider
        self.prefix = prefix ?? provider.defaultPrefix
        self.displayName = displayName ?? provider.label
        self.baseURL = baseURL
        self.model = model
    }

    var normalizedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var credentialAccount: String {
        let endpointIdentity = "\(provider.rawValue)|\(normalizedBaseURL.lowercased())"
        let digest = SHA256.hash(data: Data(endpointIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "llm-api-key-\(digest)"
    }

    var defaultModelReference: String? {
        guard !normalizedPrefix.isEmpty, !normalizedModel.isEmpty else { return nil }
        return "\(normalizedPrefix)/\(normalizedModel)"
    }

    func changingProvider(to newProvider: LLMProviderKind) -> LLMProviderProfile {
        guard newProvider != provider else { return self }
        return LLMProviderProfile(
            id: id,
            provider: newProvider,
            prefix: newProvider.defaultPrefix,
            displayName: newProvider.label,
            baseURL: newProvider.defaultBaseURL,
            model: newProvider.defaultModel
        )
    }

    func completionEndpoint() throws -> URL {
        let value = normalizedBaseURL
        guard !value.isEmpty, var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw LLMConfigurationError.invalidEndpoint
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw LLMConfigurationError.insecureEndpoint
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            components.path = "/" + path
        } else {
            components.path = "/" + ([path, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        guard let endpoint = components.url else {
            throw LLMConfigurationError.invalidEndpoint
        }
        return endpoint
    }

    func validated() throws -> LLMProviderProfile {
        _ = try completionEndpoint()
        let providerPrefix = normalizedPrefix
        guard !providerPrefix.isEmpty,
              providerPrefix.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw LLMConfigurationError.invalidProviderPrefix
        }
        guard !normalizedDisplayName.isEmpty else {
            throw LLMConfigurationError.missingProviderName
        }
        var copy = self
        copy.prefix = providerPrefix
        copy.displayName = normalizedDisplayName
        copy.baseURL = normalizedBaseURL
        copy.model = normalizedModel
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case prefix
        case displayName
        case baseURL
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(LLMProviderKind.self, forKey: .provider)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
            ?? Self.inferredPrefix(provider: provider, baseURL: baseURL)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? provider.label
    }

    private static func inferredPrefix(provider: LLMProviderKind, baseURL: String) -> String {
        guard provider == .openAICompatible,
              let host = URL(string: baseURL)?.host?.lowercased() else {
            return provider.defaultPrefix
        }
        if host.contains("minimax") { return LLMProviderKind.miniMax.defaultPrefix }
        if host.contains("deepinfra") { return LLMProviderKind.deepInfra.defaultPrefix }
        if host.contains("z.ai") { return LLMProviderKind.zAI.defaultPrefix }
        return provider.defaultPrefix
    }
}

enum LLMUseCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case translation
    case subtitleProcessing
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translation: "Translation"
        case .subtitleProcessing: "Subtitle cleanup"
        case .chat: "AI editing chat"
        }
    }

    var detail: String {
        switch self {
        case .translation: "Translates timed subtitle cues."
        case .subtitleProcessing: "Corrects ASR text, adds punctuation, and segments subtitle cues."
        case .chat: "Plans and applies edits from the editor's left chat panel."
        }
    }
}

struct LLMRequestPolicy: Codable, Equatable, Sendable {
    var timeoutSeconds: Double
    var maximumAttemptsPerModel: Int
    var initialBackoffSeconds: Double

    static func `default`(for useCase: LLMUseCase) -> LLMRequestPolicy {
        switch useCase {
        case .translation, .subtitleProcessing:
            LLMRequestPolicy(
                timeoutSeconds: 600,
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.75
            )
        case .chat:
            LLMRequestPolicy(
                timeoutSeconds: 300,
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.5
            )
        }
    }

    func validated() throws -> LLMRequestPolicy {
        guard timeoutSeconds.isFinite, (15...1_800).contains(timeoutSeconds) else {
            throw LLMConfigurationError.invalidTimeout
        }
        guard (1...4).contains(maximumAttemptsPerModel) else {
            throw LLMConfigurationError.invalidRetryCount
        }
        guard initialBackoffSeconds.isFinite, (0...10).contains(initialBackoffSeconds) else {
            throw LLMConfigurationError.invalidBackoff
        }
        return self
    }
}

struct LLMModelRoute: Codable, Equatable, Sendable {
    var primaryModel: String
    var fallbackModels: [String]
    var policy: LLMRequestPolicy

    static func `default`(for useCase: LLMUseCase) -> LLMModelRoute {
        switch useCase {
        case .translation:
            LLMModelRoute(
                primaryModel: "openai/gpt-5.4-nano",
                fallbackModels: ["minimax/MiniMax-M3"],
                policy: .default(for: useCase)
            )
        case .subtitleProcessing:
            LLMModelRoute(
                primaryModel: "openai/gpt-5.6-luna",
                fallbackModels: ["minimax/MiniMax-M3"],
                policy: .default(for: useCase)
            )
        case .chat:
            LLMModelRoute(
                primaryModel: "minimax/MiniMax-M3",
                fallbackModels: ["openai/gpt-5.4-nano"],
                policy: .default(for: useCase)
            )
        }
    }

    var modelChain: [String] {
        var seen: Set<String> = []
        return ([primaryModel] + fallbackModels).compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }
}

struct LLMRuntimeConfiguration: Sendable {
    let profile: LLMProviderProfile
    let modelIdentifier: String
    let modelName: String
    let endpoint: URL
    let apiKey: String

    var openAICompatibleRequestOptions: LLMOpenAICompatibleRequestOptions {
        let host = endpoint.host?.lowercased() ?? ""
        let normalizedModel = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isMiniMax = profile.provider == .miniMax
            || profile.normalizedPrefix == LLMProviderKind.miniMax.defaultPrefix
            || host.hasSuffix("minimax.io")
        if isMiniMax {
            return LLMOpenAICompatibleRequestOptions(
                reasoningSplit: true,
                thinkingType: normalizedModel == "minimax-m3" ? "disabled" : nil
            )
        }

        // DeepSeek V4 defaults to thinking mode with high effort. Structured
        // subtitle/translation completions wait for the full non-streaming
        // response, so leave thinking disabled unless the caller opts in.
        let isDeepSeek = profile.normalizedPrefix.caseInsensitiveCompare("deepseek") == .orderedSame
            || host.contains("deepseek.com")
            || normalizedModel.hasPrefix("deepseek-")
        if isDeepSeek {
            return LLMOpenAICompatibleRequestOptions(thinkingType: "disabled")
        }

        return .init()
    }
}

struct LLMOpenAICompatibleRequestOptions: Equatable, Sendable {
    var reasoningSplit: Bool?
    var thinkingType: String?

    init(reasoningSplit: Bool? = nil, thinkingType: String? = nil) {
        self.reasoningSplit = reasoningSplit
        self.thinkingType = thinkingType
    }

    func apply(to body: inout [String: Any]) {
        if let reasoningSplit { body["reasoning_split"] = reasoningSplit }
        if let thinkingType { body["thinking"] = ["type": thinkingType] }
    }
}

struct LLMRuntimeRoute: Sendable {
    let useCase: LLMUseCase
    let configurations: [LLMRuntimeConfiguration]
    let policy: LLMRequestPolicy
}

enum LLMConfigurationError: LocalizedError {
    case invalidEndpoint
    case insecureEndpoint
    case missingProviderName
    case invalidProviderPrefix
    case duplicateProviderPrefix(String)
    case missingModel
    case invalidModelReference(String)
    case missingProvider(String)
    case missingAPIKey
    case noConfiguredModel(LLMUseCase)
    case invalidTimeout
    case invalidRetryCount
    case invalidBackoff
    case cannotRemoveLastProvider

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid provider base URL without credentials, query parameters, or fragments."
        case .insecureEndpoint:
            "Remote LLM providers must use HTTPS. HTTP is allowed only for localhost."
        case .missingProviderName:
            "Enter a provider name."
        case .invalidProviderPrefix:
            "Use a provider prefix containing letters, numbers, periods, underscores, or hyphens."
        case .duplicateProviderPrefix(let prefix):
            "The provider prefix “\(prefix)” is already in use."
        case .missingModel:
            "Enter a model name."
        case .invalidModelReference(let value):
            "Use provider/model format for “\(value)”."
        case .missingProvider(let prefix):
            "No provider is configured with the prefix “\(prefix)”."
        case .missingAPIKey:
            "Add an API key in Settings > AI before running this flow."
        case .noConfiguredModel(let useCase):
            "Configure an API key and an available provider/model route for \(useCase.title.lowercased())."
        case .invalidTimeout:
            "Set timeout between 15 and 1,800 seconds."
        case .invalidRetryCount:
            "Set retry attempts between 1 and 4."
        case .invalidBackoff:
            "Set initial retry delay between 0 and 10 seconds."
        case .cannotRemoveLastProvider:
            "Keep at least one LLM provider."
        }
    }
}

@Observable
@MainActor
final class LLMSettingsStore {
    static let shared = LLMSettingsStore()

    private struct PersistedConfiguration: Codable {
        var providers: [LLMProviderProfile]
        var routes: [LLMUseCase: LLMModelRoute]
    }

    private static let configurationDefaultsKey = "voxella.llm.configuration.v2"
    private static let legacyProfileDefaultsKey = "voxella.llm.provider-profile.v1"

    private(set) var providers: [LLMProviderProfile]
    private(set) var routes: [LLMUseCase: LLMModelRoute]
    private(set) var credentialAvailability: [UUID: Bool] = [:]
    private(set) var credentialError: String?

    var hasAPIKey: Bool {
        credentialAvailability.values.contains(true)
    }

    private let defaults: UserDefaults
    private var credentialGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.configurationDefaultsKey),
           let saved = try? JSONDecoder().decode(PersistedConfiguration.self, from: data),
           !saved.providers.isEmpty {
            providers = saved.providers
            routes = saved.routes
        } else if let data = defaults.data(forKey: Self.legacyProfileDefaultsKey),
                  let legacy = try? JSONDecoder().decode(LLMProviderProfile.self, from: data) {
            let migratedProviders = Self.migratedProviders(from: legacy)
            providers = migratedProviders
            routes = Self.migratedRoutes(from: legacy, providers: migratedProviders)
        } else {
            providers = [.defaultOpenAI, .defaultMiniMax]
            routes = Dictionary(uniqueKeysWithValues: LLMUseCase.allCases.map {
                ($0, LLMModelRoute.default(for: $0))
            })
        }
        for useCase in LLMUseCase.allCases where routes[useCase] == nil {
            routes[useCase] = .default(for: useCase)
        }
        migrateLegacySubtitleRouteIfNeeded()
        persist()
        refreshCredentialStatus()
    }

    func provider(id: UUID) -> LLMProviderProfile? {
        providers.first { $0.id == id }
    }

    func route(for useCase: LLMUseCase) -> LLMModelRoute {
        routes[useCase] ?? .default(for: useCase)
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        credentialAvailability[providerID] == true
    }

    func hasConfiguredModel(for useCase: LLMUseCase) -> Bool {
        route(for: useCase).modelChain.contains { reference in
            guard let parsed = try? Self.parseModelReference(reference),
                  let provider = providers.first(where: {
                      $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                  }) else { return false }
            return hasAPIKey(for: provider.id)
        }
    }

    @discardableResult
    func addProvider(kind: LLMProviderKind) -> UUID {
        let prefix = uniquePrefix(basedOn: kind.defaultPrefix)
        let profile = LLMProviderProfile(
            provider: kind,
            prefix: prefix,
            displayName: kind.label,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModel
        )
        providers.append(profile)
        persist()
        refreshCredentialStatus()
        return profile.id
    }

    func updateProvider(_ profile: LLMProviderProfile) throws {
        let validated = try profile.validated()
        guard !providers.contains(where: {
            $0.id != validated.id
                && $0.normalizedPrefix.caseInsensitiveCompare(validated.normalizedPrefix) == .orderedSame
        }) else {
            throw LLMConfigurationError.duplicateProviderPrefix(validated.normalizedPrefix)
        }
        guard let index = providers.firstIndex(where: { $0.id == validated.id }) else {
            throw LLMConfigurationError.missingProvider(validated.normalizedPrefix)
        }
        providers[index] = validated
        persist()
        refreshCredentialStatus()
    }

    func removeProvider(id: UUID) async throws {
        guard providers.count > 1 else {
            throw LLMConfigurationError.cannotRemoveLastProvider
        }
        guard let profile = provider(id: id) else { return }
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.deleteProtected(account: profile.credentialAccount)
        }.value
        providers.removeAll { $0.id == id }
        credentialAvailability[id] = nil
        persist()
    }

    func updateRoute(_ route: LLMModelRoute, for useCase: LLMUseCase) throws {
        let validatedPolicy = try route.policy.validated()
        let references = route.modelChain
        guard let primary = references.first else { throw LLMConfigurationError.missingModel }
        for reference in references {
            let parsed = try Self.parseModelReference(reference)
            guard providers.contains(where: {
                $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
            }) else {
                throw LLMConfigurationError.missingProvider(parsed.prefix)
            }
        }
        routes[useCase] = LLMModelRoute(
            primaryModel: primary,
            fallbackModels: Array(references.dropFirst()),
            policy: validatedPolicy
        )
        persist()
    }

    func refreshCredentialStatus() {
        credentialGeneration += 1
        let generation = credentialGeneration
        let profiles = providers
        Task {
            var statuses: [UUID: Bool] = [:]
            var statusError: String?
            for profile in profiles {
                do {
                    let exists = try await Task.detached(priority: .utility) {
                        try KeychainStore.containsProtected(account: profile.credentialAccount)
                    }.value
                    statuses[profile.id] = exists
                } catch {
                    statuses[profile.id] = false
                    statusError = error.localizedDescription
                }
            }
            guard generation == credentialGeneration else { return }
            credentialAvailability = statuses
            credentialError = statusError
        }
    }

    func credentialAvailable() async -> Bool {
        credentialGeneration += 1
        let generation = credentialGeneration
        let profiles = providers
        var statuses: [UUID: Bool] = [:]
        var statusError: String?
        for profile in profiles {
            do {
                statuses[profile.id] = try await Task.detached(priority: .utility) {
                    try KeychainStore.containsProtected(account: profile.credentialAccount)
                }.value
            } catch {
                statuses[profile.id] = false
                statusError = error.localizedDescription
            }
        }
        guard generation == credentialGeneration else { return hasAPIKey }
        credentialAvailability = statuses
        credentialError = statusError
        return hasAPIKey
    }

    func saveAPIKey(_ value: String, providerID: UUID) async throws {
        guard let profile = provider(id: providerID) else {
            throw LLMConfigurationError.missingProvider("")
        }
        credentialGeneration += 1
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.saveProtected(value, account: profile.credentialAccount)
        }.value
        guard provider(id: providerID)?.credentialAccount == profile.credentialAccount else { return }
        credentialAvailability[providerID] = true
        credentialError = nil
    }

    func deleteAPIKey(providerID: UUID) async throws {
        guard let profile = provider(id: providerID) else {
            throw LLMConfigurationError.missingProvider("")
        }
        credentialGeneration += 1
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.deleteProtected(account: profile.credentialAccount)
        }.value
        guard provider(id: providerID)?.credentialAccount == profile.credentialAccount else { return }
        credentialAvailability[providerID] = false
        credentialError = nil
    }

    func runtimeRoute(for useCase: LLMUseCase) async throws -> LLMRuntimeRoute {
        let route = route(for: useCase)
        let policy = try route.policy.validated()
        var configurations: [LLMRuntimeConfiguration] = []
        var firstCredentialError: Error?

        for reference in route.modelChain {
            let parsed = try Self.parseModelReference(reference)
            guard let profile = providers.first(where: {
                $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
            }) else { continue }
            let validated = try profile.validated()
            do {
                guard let key = try await Task.detached(priority: .userInitiated, operation: {
                    try KeychainStore.loadProtected(account: validated.credentialAccount)
                }).value else {
                    continue
                }
                configurations.append(LLMRuntimeConfiguration(
                    profile: validated,
                    modelIdentifier: "\(validated.normalizedPrefix)/\(parsed.model)",
                    modelName: parsed.model,
                    endpoint: try validated.completionEndpoint(),
                    apiKey: key
                ))
            } catch {
                firstCredentialError = firstCredentialError ?? error
            }
        }

        if configurations.isEmpty {
            if let firstCredentialError { throw firstCredentialError }
            throw LLMConfigurationError.noConfiguredModel(useCase)
        }
        return LLMRuntimeRoute(
            useCase: useCase,
            configurations: configurations,
            policy: policy
        )
    }

    func runtimeConfiguration() async throws -> LLMRuntimeConfiguration {
        guard let configuration = try await runtimeRoute(for: .subtitleProcessing).configurations.first else {
            throw LLMConfigurationError.missingAPIKey
        }
        return configuration
    }

    static func parseModelReference(_ value: String) throws -> (prefix: String, model: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = normalized.firstIndex(of: "/") else {
            throw LLMConfigurationError.invalidModelReference(value)
        }
        let prefix = normalized[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let model = normalized[normalized.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !model.isEmpty else {
            throw LLMConfigurationError.invalidModelReference(value)
        }
        return (prefix, model)
    }

    private func uniquePrefix(basedOn base: String) -> String {
        let used = Set(providers.map { $0.normalizedPrefix.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func persist() {
        let configuration = PersistedConfiguration(providers: providers, routes: routes)
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.configurationDefaultsKey)
        }
    }

    private static func migratedProviders(from legacy: LLMProviderProfile) -> [LLMProviderProfile] {
        var migrated = legacy
        if migrated.normalizedPrefix == LLMProviderKind.openAICompatible.defaultPrefix,
           let inferred = migrated.defaultModelReference?.split(separator: "/").first {
            migrated.prefix = String(inferred)
        }
        var result = [migrated]
        if !result.contains(where: { $0.normalizedPrefix == "openai" }) {
            result.append(.defaultOpenAI)
        }
        if !result.contains(where: { $0.normalizedPrefix == "minimax" }) {
            result.append(.defaultMiniMax)
        }
        return result
    }

    private static func migratedRoutes(
        from legacy: LLMProviderProfile,
        providers: [LLMProviderProfile]
    ) -> [LLMUseCase: LLMModelRoute] {
        let legacyReference = providers.first(where: { $0.id == legacy.id })?.defaultModelReference
            ?? legacy.defaultModelReference
        var result = Dictionary(uniqueKeysWithValues: LLMUseCase.allCases.map {
            ($0, LLMModelRoute.default(for: $0))
        })
        guard let legacyReference else { return result }
        for useCase in LLMUseCase.allCases {
            var route = result[useCase]!
            if !route.modelChain.contains(where: {
                $0.caseInsensitiveCompare(legacyReference) == .orderedSame
            }) {
                route.fallbackModels.insert(legacyReference, at: 0)
            }
            result[useCase] = route
        }
        return result
    }

    private func migrateLegacySubtitleRouteIfNeeded() {
        let legacyDefault = LLMModelRoute(
            primaryModel: "openai/gpt-5.4-nano",
            fallbackModels: ["minimax/MiniMax-M3"],
            policy: .default(for: .subtitleProcessing)
        )
        guard routes[.subtitleProcessing] == legacyDefault else { return }
        routes[.subtitleProcessing] = .default(for: .subtitleProcessing)
    }
}
