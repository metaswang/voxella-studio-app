import CryptoKit
import Foundation
import Observation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case miniMax
    case deepInfra
    case zAI
    case openRouter
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .miniMax: "MiniMax"
        case .deepInfra: "DeepInfra"
        case .zAI: "Z.AI"
        case .openRouter: "OpenRouter"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    var defaultPrefix: String {
        switch self {
        case .openAI: "openai"
        case .miniMax: "minimax"
        case .deepInfra: "deepinfra"
        case .zAI: "zai"
        case .openRouter: "openrouter"
        case .openAICompatible: "provider"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .miniMax: "https://api.minimax.io/v1"
        case .deepInfra: "https://api.deepinfra.com/v1/openai"
        case .zAI: "https://api.z.ai/api/paas/v4"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAICompatible: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.4-nano"
        case .miniMax: "MiniMax-M3"
        case .deepInfra, .zAI, .openRouter, .openAICompatible: ""
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
    var extraBody: [String: LLMJSONValue]
    var openRouterRouting: LLMOpenRouterRouting

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
        model: String,
        extraBody: [String: LLMJSONValue] = [:],
        openRouterRouting: LLMOpenRouterRouting = .init()
    ) {
        self.id = id
        self.provider = provider
        self.prefix = prefix ?? provider.defaultPrefix
        self.displayName = displayName ?? provider.label
        self.baseURL = baseURL
        self.model = model
        self.extraBody = extraBody
        self.openRouterRouting = openRouterRouting
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
        "llm-api-key-v2-\(id.uuidString.lowercased())"
    }

    var legacyCredentialAccount: String {
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
        case extraBody
        case openRouterRouting
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
        extraBody = try container.decodeIfPresent(
            [String: LLMJSONValue].self,
            forKey: .extraBody
        ) ?? [:]
        openRouterRouting = try container.decodeIfPresent(
            LLMOpenRouterRouting.self,
            forKey: .openRouterRouting
        ) ?? .init()
    }

    private static func inferredPrefix(provider: LLMProviderKind, baseURL: String) -> String {
        guard provider == .openAICompatible,
              let host = URL(string: baseURL)?.host?.lowercased() else {
            return provider.defaultPrefix
        }
        if host.contains("minimax") { return LLMProviderKind.miniMax.defaultPrefix }
        if host.contains("deepinfra") { return LLMProviderKind.deepInfra.defaultPrefix }
        if host.contains("z.ai") { return LLMProviderKind.zAI.defaultPrefix }
        if host.contains("openrouter.ai") { return LLMProviderKind.openRouter.defaultPrefix }
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
        case .subtitleProcessing: "Segments subtitle cues. Repairs punctuation only when ASR did not already punctuate."
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
        case .subtitleProcessing:
            LLMRequestPolicy(
                timeoutSeconds: minimumTimeoutSeconds(for: useCase),
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.75
            )
        case .translation:
            LLMRequestPolicy(
                timeoutSeconds: minimumTimeoutSeconds(for: useCase),
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.75
            )
        case .chat:
            LLMRequestPolicy(
                timeoutSeconds: 60,
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.5
            )
        }
    }

    static func minimumTimeoutSeconds(for useCase: LLMUseCase) -> Double {
        switch useCase {
        case .subtitleProcessing: 90
        case .translation: 45
        case .chat: 15
        }
    }

    func validated() throws -> LLMRequestPolicy {
        try validated(for: .chat)
    }

    func validated(for useCase: LLMUseCase) throws -> LLMRequestPolicy {
        guard timeoutSeconds.isFinite, (15...1_800).contains(timeoutSeconds) else {
            throw LLMConfigurationError.invalidTimeout
        }
        guard (1...4).contains(maximumAttemptsPerModel) else {
            throw LLMConfigurationError.invalidRetryCount
        }
        guard initialBackoffSeconds.isFinite, (0...10).contains(initialBackoffSeconds) else {
            throw LLMConfigurationError.invalidBackoff
        }
        var normalized = self
        let minimum = Self.minimumTimeoutSeconds(for: useCase)
        if normalized.timeoutSeconds < minimum {
            normalized.timeoutSeconds = minimum
        }
        return normalized
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
    let useCase: LLMUseCase?

    init(
        profile: LLMProviderProfile,
        modelIdentifier: String,
        modelName: String,
        endpoint: URL,
        apiKey: String,
        useCase: LLMUseCase? = nil
    ) {
        self.profile = profile
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.useCase = useCase
    }

    var openAICompatibleRequestOptions: LLMOpenAICompatibleRequestOptions {
        var options = providerRequestOptions
        if useCase == .subtitleProcessing || useCase == .translation {
            options.suppressThinking(
                canDisableThinking: canDisableThinking,
                disableReasoning: disablesReasoningForStructuredOutput
            )
            options.temperature = 0
            options.maxOutputTokens = useCase == .translation ? 8_192 : 4_096
        }
        return options
    }

    private var providerRequestOptions: LLMOpenAICompatibleRequestOptions {
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

    private var canDisableThinking: Bool {
        let host = endpoint.host?.lowercased() ?? ""
        let isMiniMax = profile.provider == .miniMax
            || profile.normalizedPrefix == LLMProviderKind.miniMax.defaultPrefix
            || host.hasSuffix("minimax.io")
        guard isMiniMax else { return true }
        return modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "minimax-m3"
    }

    // OpenRouter/Gemini treat reasoning.effort as enabling thinking.
    private var disablesReasoningForStructuredOutput: Bool {
        if profile.isOpenRouter { return true }
        let host = endpoint.host?.lowercased() ?? ""
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model.contains("gemini") { return true }
        if host.contains("googleapis.com") || host.contains("generativelanguage") {
            return true
        }
        let prefix = profile.normalizedPrefix
        return prefix == "google" || prefix == "gemini"
    }
}

struct LLMOpenAICompatibleRequestOptions: Equatable, Sendable {
    var reasoningSplit: Bool?
    var thinkingType: String?
    var reasoningEffort: String?
    var reasoningEnabled: Bool?
    var temperature: Double?
    var maxOutputTokens: Int?

    init(
        reasoningSplit: Bool? = nil,
        thinkingType: String? = nil,
        reasoningEffort: String? = nil,
        reasoningEnabled: Bool? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.reasoningSplit = reasoningSplit
        self.thinkingType = thinkingType
        self.reasoningEffort = reasoningEffort
        self.reasoningEnabled = reasoningEnabled
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }

    mutating func suppressThinking(
        canDisableThinking: Bool,
        disableReasoning: Bool = false
    ) {
        let hadProviderThinking = thinkingType != nil || reasoningSplit != nil
        if thinkingType == nil, canDisableThinking {
            thinkingType = "disabled"
        }
        if disableReasoning {
            reasoningEnabled = false
            reasoningEffort = nil
            return
        }
        if reasoningEffort == nil, !hadProviderThinking {
            reasoningEffort = "none"
        }
    }

    var extraBody: [String: LLMJSONValue] {
        var result: [String: LLMJSONValue] = [:]
        if let reasoningSplit {
            result["reasoning_split"] = .bool(reasoningSplit)
        }
        if let thinkingType {
            result["thinking"] = .object(["type": .string(thinkingType)])
        }
        var reasoning: [String: LLMJSONValue] = [:]
        if let reasoningEnabled {
            reasoning["enabled"] = .bool(reasoningEnabled)
        }
        if let reasoningEffort {
            reasoning["effort"] = .string(reasoningEffort)
        }
        if !reasoning.isEmpty {
            result["reasoning"] = .object(reasoning)
        }
        if let temperature {
            result["temperature"] = .number(temperature)
        }
        if let maxOutputTokens {
            result["max_tokens"] = .number(Double(maxOutputTokens))
        }
        return result
    }

    func apply(to body: inout [String: Any]) {
        if let reasoningSplit { body["reasoning_split"] = reasoningSplit }
        if let thinkingType { body["thinking"] = ["type": thinkingType] }
        var reasoning: [String: Any] = [:]
        if let reasoningEnabled { reasoning["enabled"] = reasoningEnabled }
        if let reasoningEffort { reasoning["effort"] = reasoningEffort }
        if !reasoning.isEmpty { body["reasoning"] = reasoning }
        if let temperature { body["temperature"] = temperature }
        if let maxOutputTokens { body["max_tokens"] = maxOutputTokens }
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

enum LLMAPIKeySaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

@Observable
@MainActor
final class LLMSettingsStore {
    static let shared = LLMSettingsStore()

    struct PersistedConfiguration: Codable {
        var providers: [LLMProviderProfile]
        var routes: [LLMUseCase: LLMModelRoute]
    }

    private enum ConfigurationLoad {
        case missing
        case valid(PersistedConfiguration)
        case invalid
    }

    private static let applicationDefaultsSuiteName = "com.voxella.studio"
    private static let legacyDefaultsSuiteNames = [
        "VoxellaStudio",
        "PalmierPro",
        "io.palmier.pro"
    ]
    private static let configurationDefaultsKey = "voxella.llm.configuration.v2"
    private static let legacyProfileDefaultsKey = "voxella.llm.provider-profile.v1"
    private static let subtitleRouteMigrationKey = "voxella.llm.migration.subtitle-route.v1"
    private static let performanceRoutingMigrationKey = "voxella.llm.migration.performance-routing.v1"
    private static let useBYOKKey = "voxella.llm.use-byok.v1"
    private static let useBYOKMigrationKey = "voxella.llm.migration.use-byok.v1"

    private(set) var providers: [LLMProviderProfile]
    private(set) var routes: [LLMUseCase: LLMModelRoute]
    private(set) var credentialAvailability: [UUID: Bool] = [:]
    private(set) var credentialSaveStates: [UUID: LLMAPIKeySaveState] = [:]
    private(set) var credentialError: String?
    private(set) var configurationError: String?

    var useBYOK: Bool {
        didSet {
            defaults.set(useBYOK, forKey: Self.useBYOKKey)
            defaults.set(true, forKey: Self.useBYOKMigrationKey)
        }
    }

    var hasAPIKey: Bool {
        credentialAvailability.values.contains(true)
    }

    private let defaults: UserDefaults
    private let credentialSaver: @Sendable (String, LLMProviderProfile) async throws -> Void
    private var credentialGeneration = 0
    private var pendingCredentialValues: [UUID: String] = [:]
    private var pendingCredentialTasks: [UUID: Task<Void, Never>] = [:]
    private var credentialSaveGeneration: [UUID: Int] = [:]

    init(
        defaults: UserDefaults? = nil,
        legacyDefaults: [UserDefaults]? = nil,
        credentialSaver: (@Sendable (String, LLMProviderProfile) async throws -> Void)? = nil
    ) {
        let usesApplicationDefaults = defaults == nil
        let defaults = defaults ?? Self.applicationDefaults
        let historicalDefaults = legacyDefaults
            ?? (usesApplicationDefaults ? Self.legacyDefaults : [])
        self.defaults = defaults
        self.credentialSaver = credentialSaver ?? Self.persistCredentialToKeychain
        self.useBYOK = defaults.object(forKey: Self.useBYOKKey) as? Bool ?? false
        var shouldPersist = false

        switch Self.loadConfiguration(from: defaults) {
        case .valid(let saved):
            providers = saved.providers
            routes = saved.routes
        case .invalid:
            providers = [.defaultOpenAI, .defaultMiniMax]
            routes = Self.defaultRoutes
            configurationError = "Saved AI settings could not be read. They were left unchanged."
        case .missing:
            if let data = defaults.data(forKey: Self.legacyProfileDefaultsKey),
               let legacy = try? JSONDecoder().decode(LLMProviderProfile.self, from: data) {
                let migratedProviders = Self.migratedProviders(from: legacy)
                providers = migratedProviders
                routes = Self.migratedRoutes(from: legacy, providers: migratedProviders)
                shouldPersist = true
            } else if let legacy = Self.loadLegacyProfile(from: historicalDefaults) {
                let migratedProviders = Self.migratedProviders(from: legacy)
                providers = migratedProviders
                routes = Self.migratedRoutes(from: legacy, providers: migratedProviders)
                shouldPersist = true
            } else if let migrated = Self.loadConfiguration(
                from: historicalDefaults
            ) {
                providers = migrated.providers
                routes = migrated.routes
                shouldPersist = true
            } else {
                providers = [.defaultOpenAI, .defaultMiniMax]
                routes = Self.defaultRoutes
                shouldPersist = true
            }
        }

        for useCase in LLMUseCase.allCases where routes[useCase] == nil {
            routes[useCase] = .default(for: useCase)
            shouldPersist = true
        }
        if migrateLegacySubtitleRouteIfNeeded() {
            shouldPersist = true
        }
        if migratePerformanceRoutingIfNeeded() {
            shouldPersist = true
        }
        if migrateSubtitleTimeoutIfNeeded() {
            shouldPersist = true
        }
        if normalizeRoutesForProviderRouting() {
            shouldPersist = true
        }
        if shouldPersist, configurationError == nil {
            persist()
        }
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

    func apiKeySaveState(for providerID: UUID) -> LLMAPIKeySaveState {
        credentialSaveStates[providerID] ?? .idle
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

    func hasUsableModel(for useCase: LLMUseCase) -> Bool {
        switch AITransportPolicy.current {
        case .hosted:
            true
        case .byok:
            hasConfiguredModel(for: useCase)
        case .unavailable:
            false
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
        _ = normalizeRoutesForProviderRouting()
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
            try KeychainStore.deleteProtected(account: profile.legacyCredentialAccount)
        }.value
        providers.removeAll { $0.id == id }
        credentialAvailability[id] = nil
        credentialSaveStates[id] = nil
        credentialSaveGeneration[id] = nil
        persist()
    }

    func updateRoute(_ route: LLMModelRoute, for useCase: LLMUseCase) throws {
        let validatedPolicy = try route.policy.validated(for: useCase)
        let references = route.modelChain.map(effectiveModelReference)
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
                    statuses[profile.id] = try await loadCredential(for: profile) != nil
                } catch {
                    statuses[profile.id] = false
                    statusError = error.localizedDescription
                }
            }
            guard generation == credentialGeneration else { return }
            credentialAvailability = statuses
            credentialError = statusError
            if self.defaults.object(forKey: Self.useBYOKMigrationKey) == nil {
                // Existing installs with a stored provider key keep their old
                // behavior. New installs remain hosted by default.
                var hasLegacyAgentKey = false
                for provider in AgentProvider.allCases {
                    if !(await provider.loadAPIKey()).isEmpty {
                        hasLegacyAgentKey = true
                        break
                    }
                }
                if statuses.values.contains(true) || hasLegacyAgentKey {
                    useBYOK = true
                }
                self.defaults.set(true, forKey: Self.useBYOKMigrationKey)
            }
        }
    }

    func scheduleAPIKeySave(_ value: String, providerID: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, provider(id: providerID) != nil else { return }

        let generation = nextCredentialSaveGeneration(for: providerID)
        pendingCredentialTasks[providerID]?.cancel()
        pendingCredentialValues[providerID] = trimmed
        credentialSaveStates[providerID] = .saving
        credentialError = nil
        pendingCredentialTasks[providerID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard let self,
                  self.pendingCredentialValues[providerID] == trimmed,
                  self.credentialSaveGeneration[providerID] == generation else { return }
            self.pendingCredentialValues[providerID] = nil
            self.pendingCredentialTasks[providerID] = nil
            await self.persistAPIKey(trimmed, providerID: providerID, generation: generation)
        }
    }

    func flushAPIKeySave(for providerID: UUID) {
        guard let value = pendingCredentialValues[providerID] else { return }
        let generation = nextCredentialSaveGeneration(for: providerID)
        pendingCredentialTasks[providerID]?.cancel()
        pendingCredentialTasks[providerID] = nil
        pendingCredentialValues[providerID] = nil
        credentialSaveStates[providerID] = .saving
        startPersistingAPIKey(value, providerID: providerID, generation: generation)
    }

    func cancelPendingAPIKeySave(for providerID: UUID) {
        let hadPendingValue = pendingCredentialValues[providerID] != nil
        pendingCredentialTasks[providerID]?.cancel()
        pendingCredentialTasks[providerID] = nil
        pendingCredentialValues[providerID] = nil
        guard hadPendingValue else { return }
        _ = nextCredentialSaveGeneration(for: providerID)
        credentialSaveStates[providerID] = hasAPIKey(for: providerID) ? .saved : .idle
    }

    func credentialAvailable() async -> Bool {
        credentialGeneration += 1
        let generation = credentialGeneration
        let profiles = providers
        var statuses: [UUID: Bool] = [:]
        var statusError: String?
        for profile in profiles {
            do {
                statuses[profile.id] = try await loadCredential(for: profile) != nil
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
        cancelPendingAPIKeySave(for: providerID)
        let generation = nextCredentialSaveGeneration(for: providerID)
        credentialSaveStates[providerID] = .saving
        do {
            try await saveAPIKeyImmediately(value, providerID: providerID)
            guard isCurrentCredentialSave(generation, for: providerID) else { return }
            credentialSaveStates[providerID] = .saved
        } catch {
            if isCurrentCredentialSave(generation, for: providerID) {
                let message = error.localizedDescription
                credentialSaveStates[providerID] = .failed(message)
                credentialError = message
            }
            throw error
        }
    }

    func loadAPIKey(for providerID: UUID) async throws -> String? {
        guard let profile = provider(id: providerID) else {
            throw LLMConfigurationError.missingProvider("")
        }
        return try await loadCredential(for: profile)
    }

    private func startPersistingAPIKey(
        _ value: String,
        providerID: UUID,
        generation: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistAPIKey(value, providerID: providerID, generation: generation)
        }
    }

    private func persistAPIKey(
        _ value: String,
        providerID: UUID,
        generation: Int
    ) async {
        do {
            try await saveAPIKeyImmediately(value, providerID: providerID)
            guard isCurrentCredentialSave(generation, for: providerID) else { return }
            credentialSaveStates[providerID] = .saved
        } catch {
            guard !Task.isCancelled, isCurrentCredentialSave(generation, for: providerID) else {
                return
            }
            let message = error.localizedDescription
            credentialSaveStates[providerID] = .failed(message)
            credentialError = message
        }
    }

    private func nextCredentialSaveGeneration(for providerID: UUID) -> Int {
        let generation = (credentialSaveGeneration[providerID] ?? 0) + 1
        credentialSaveGeneration[providerID] = generation
        return generation
    }

    private func isCurrentCredentialSave(_ generation: Int, for providerID: UUID) -> Bool {
        credentialSaveGeneration[providerID] == generation
    }

    private func saveAPIKeyImmediately(_ value: String, providerID: UUID) async throws {
        guard let profile = provider(id: providerID) else {
            throw LLMConfigurationError.missingProvider("")
        }
        credentialGeneration += 1
        try await credentialSaver(value, profile)
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
            try KeychainStore.deleteProtected(account: profile.legacyCredentialAccount)
        }.value
        guard provider(id: providerID)?.credentialAccount == profile.credentialAccount else { return }
        credentialAvailability[providerID] = false
        credentialSaveStates[providerID] = .idle
        credentialError = nil
    }

    private func loadCredential(for profile: LLMProviderProfile) async throws -> String? {
        do {
            return try await Task.detached(priority: .utility) {
                try Self.loadCredentialSynchronously(for: profile)
            }.value
        } catch let error as KeychainStoreError where error.isInteractionNotAllowed {
            return try await MainActor.run {
                try Self.loadCredentialSynchronously(for: profile)
            }
        }
    }

    private nonisolated static func loadCredentialSynchronously(for profile: LLMProviderProfile) throws -> String? {
        if let value = try KeychainStore.loadProtected(account: profile.credentialAccount) {
            return value
        }
        guard let value = try KeychainStore.loadProtected(account: profile.legacyCredentialAccount)
        else { return nil }

        try KeychainStore.saveProtected(value, account: profile.credentialAccount)
        try? KeychainStore.deleteProtected(account: profile.legacyCredentialAccount)
        return value
    }

    func runtimeRoute(for useCase: LLMUseCase) async throws -> LLMRuntimeRoute {
        let route = route(for: useCase)
        let policy = try route.policy.validated(for: useCase)
        var configurations: [LLMRuntimeConfiguration] = []
        var firstCredentialError: Error?

        for reference in route.modelChain {
            let parsed = try Self.parseModelReference(reference)
            guard let profile = providers.first(where: {
                $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
            }) else { continue }
            let validated = try profile.validated()
            do {
                guard let key = try await loadCredential(for: validated) else {
                    continue
                }
                configurations.append(LLMRuntimeConfiguration(
                    profile: validated,
                    modelIdentifier: "\(validated.normalizedPrefix)/\(parsed.model)",
                    modelName: parsed.model,
                    endpoint: try validated.completionEndpoint(),
                    apiKey: key,
                    useCase: useCase
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

    @discardableResult
    private func migrateLegacySubtitleRouteIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Self.subtitleRouteMigrationKey) else { return false }
        defaults.set(true, forKey: Self.subtitleRouteMigrationKey)
        let legacyDefault = LLMModelRoute(
            primaryModel: "openai/gpt-5.4-nano",
            fallbackModels: ["minimax/MiniMax-M3"],
            policy: .default(for: .subtitleProcessing)
        )
        guard routes[.subtitleProcessing] == legacyDefault else { return false }
        routes[.subtitleProcessing] = .default(for: .subtitleProcessing)
        return true
    }

    @discardableResult
    private func migrateSubtitleTimeoutIfNeeded() -> Bool {
        var changed = false
        for useCase in [LLMUseCase.subtitleProcessing, .translation] {
            guard var route = routes[useCase] else { continue }
            let minimum = LLMRequestPolicy.minimumTimeoutSeconds(for: useCase)
            guard route.policy.timeoutSeconds < minimum else { continue }
            route.policy.timeoutSeconds = minimum
            routes[useCase] = route
            changed = true
        }
        return changed
    }

    @discardableResult
    private func migratePerformanceRoutingIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Self.performanceRoutingMigrationKey) else { return false }
        defaults.set(true, forKey: Self.performanceRoutingMigrationKey)

        var changed = false
        for index in providers.indices where providers[index].isOpenRouter {
            let routing = providers[index].openRouterRouting
            guard !routing.enabled, routing.order.isEmpty, routing.sort == nil else { continue }
            providers[index].openRouterRouting = LLMOpenRouterRouting(
                enabled: true,
                order: [],
                allowFallbacks: routing.allowFallbacks,
                sort: .throughput
            )
            changed = true
        }

        for useCase in LLMUseCase.allCases {
            let route = route(for: useCase)
            let references = route.modelChain.map(effectiveModelReference)
            guard references != route.modelChain else { continue }
            routes[useCase] = LLMModelRoute(
                primaryModel: references[0],
                fallbackModels: Array(references.dropFirst()),
                policy: migratedPerformancePolicy(route.policy, for: useCase)
            )
            changed = true
        }

        for useCase in LLMUseCase.allCases {
            guard var route = routes[useCase] else { continue }
            let migrated = migratedPerformancePolicy(route.policy, for: useCase)
            guard migrated != route.policy else { continue }
            route.policy = migrated
            routes[useCase] = route
            changed = true
        }
        return changed
    }

    private func normalizeRoutesForProviderRouting() -> Bool {
        var changed = false
        for useCase in LLMUseCase.allCases {
            guard let route = routes[useCase] else { continue }
            let references = route.modelChain.map(effectiveModelReference)
            guard let primary = references.first, references != route.modelChain else { continue }
            routes[useCase] = LLMModelRoute(
                primaryModel: primary,
                fallbackModels: Array(references.dropFirst()),
                policy: route.policy
            )
            changed = true
        }
        return changed
    }

    private func effectiveModelReference(_ reference: String) -> String {
        guard let parsed = try? Self.parseModelReference(reference),
              let profile = providers.first(where: {
                  $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
              }),
              profile.isOpenRouter else {
            return reference
        }

        if profile.hasExplicitProviderOrder {
            let model = Self.removingNitroVariant(from: parsed.model)
            return "\(parsed.prefix)/\(model)"
        }
        guard !parsed.model.contains(":") else { return reference }
        return "\(parsed.prefix)/\(parsed.model):nitro"
    }

    private static func removingNitroVariant(from model: String) -> String {
        let suffix = ":nitro"
        guard model.lowercased().hasSuffix(suffix) else { return model }
        return String(model.dropLast(suffix.count))
    }

    private func migratedPerformancePolicy(
        _ policy: LLMRequestPolicy,
        for useCase: LLMUseCase
    ) -> LLMRequestPolicy {
        let legacyTimeout = useCase == .chat ? 300.0 : 600.0
        let legacyBackoff = useCase == .chat ? 0.5 : 0.75
        guard policy.timeoutSeconds == legacyTimeout,
              policy.maximumAttemptsPerModel == 2,
              policy.initialBackoffSeconds == legacyBackoff else {
            return policy
        }
        return .default(for: useCase)
    }

    private static var applicationDefaults: UserDefaults {
        UserDefaults(suiteName: applicationDefaultsSuiteName) ?? .standard
    }

    private static var legacyDefaults: [UserDefaults] {
        legacyDefaultsSuiteNames.compactMap(UserDefaults.init(suiteName:))
    }

    private static var defaultRoutes: [LLMUseCase: LLMModelRoute] {
        Dictionary(uniqueKeysWithValues: LLMUseCase.allCases.map {
            ($0, LLMModelRoute.default(for: $0))
        })
    }

    private static func loadConfiguration(from defaults: UserDefaults) -> ConfigurationLoad {
        guard let data = defaults.data(forKey: configurationDefaultsKey) else {
            return .missing
        }
        guard let saved = try? JSONDecoder().decode(PersistedConfiguration.self, from: data),
              !saved.providers.isEmpty else {
            return .invalid
        }
        return .valid(saved)
    }

    private static func loadConfiguration(from defaults: [UserDefaults]) -> PersistedConfiguration? {
        for defaults in defaults {
            switch loadConfiguration(from: defaults) {
            case .valid(let saved): return saved
            case .invalid: continue
            case .missing: continue
            }
        }
        return nil
    }

    private static func loadLegacyProfile(from defaults: [UserDefaults]) -> LLMProviderProfile? {
        for defaults in defaults {
            guard let data = defaults.data(forKey: legacyProfileDefaultsKey),
                  let legacy = try? JSONDecoder().decode(LLMProviderProfile.self, from: data)
            else { continue }
            return legacy
        }
        return nil
    }

    private static func persistCredentialToKeychain(
        _ value: String,
        _ profile: LLMProviderProfile
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.saveProtected(value, account: profile.credentialAccount)
            try? KeychainStore.deleteProtected(account: profile.legacyCredentialAccount)
        }.value
    }
}
