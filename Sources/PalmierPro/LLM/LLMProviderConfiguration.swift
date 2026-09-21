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

/// Curated providers that expose the OpenAI Chat Completions protocol used by
/// the BYOK transport. Keep this list separate from `LLMProviderKind`: the
/// latter describes request behavior, while this list describes a friendly
/// setup preset that can be changed without breaking persisted configurations.
struct LLMProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let defaultModel: String
    let providerKind: LLMProviderKind
    let detail: String
    let isCustom: Bool

    var defaultPrefix: String {
        name.providerPrefix
    }

    var isLocal: Bool {
        Self.isLocalBaseURL(baseURL)
    }

    static func isLocalBaseURL(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static let custom = LLMProviderPreset(
        id: "custom",
        name: "Custom provider",
        baseURL: "",
        defaultModel: "",
        providerKind: .openAICompatible,
        detail: "Any OpenAI-compatible endpoint",
        isCustom: true
    )

    // Base URLs are OpenAI-compatible roots. The model field is a convenience
    // only; users can always replace it with a model from their provider
    // account. Local runtimes intentionally share the same editable preset
    // flow as hosted providers.
    static let presets: [LLMProviderPreset] = [
        .init(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-5.4-nano",
            providerKind: .openAI,
            detail: "Official OpenAI API",
            isCustom: false
        ),
        .init(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "",
            providerKind: .openRouter,
            detail: "One API for many model providers",
            isCustom: false
        ),
        .init(
            id: "google-gemini",
            name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.5-flash",
            providerKind: .openAICompatible,
            detail: "Gemini OpenAI-compatible endpoint",
            isCustom: false
        ),
        .init(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            providerKind: .openAICompatible,
            detail: "DeepSeek Chat / Reasoner API",
            isCustom: false
        ),
        .init(
            id: "groq",
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile",
            providerKind: .openAICompatible,
            detail: "Fast OpenAI-compatible inference",
            isCustom: false
        ),
        .init(
            id: "mistral",
            name: "Mistral AI",
            baseURL: "https://api.mistral.ai/v1",
            defaultModel: "mistral-small-latest",
            providerKind: .openAICompatible,
            detail: "Mistral platform API",
            isCustom: false
        ),
        .init(
            id: "together-ai",
            name: "Together AI",
            baseURL: "https://api.together.xyz/v1",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            providerKind: .openAICompatible,
            detail: "Open models through Together",
            isCustom: false
        ),
        .init(
            id: "fireworks-ai",
            name: "Fireworks AI",
            baseURL: "https://api.fireworks.ai/inference/v1",
            defaultModel: "accounts/fireworks/models/llama-v3p1-8b-instruct",
            providerKind: .openAICompatible,
            detail: "Fast model inference API",
            isCustom: false
        ),
        .init(
            id: "xai",
            name: "xAI",
            baseURL: "https://api.x.ai/v1",
            defaultModel: "grok-3-mini",
            providerKind: .openAICompatible,
            detail: "Grok API",
            isCustom: false
        ),
        .init(
            id: "perplexity",
            name: "Perplexity",
            baseURL: "https://api.perplexity.ai",
            defaultModel: "sonar",
            providerKind: .openAICompatible,
            detail: "Search-focused Sonar API",
            isCustom: false
        ),
        .init(
            id: "deepinfra",
            name: "DeepInfra",
            baseURL: "https://api.deepinfra.com/v1/openai",
            defaultModel: "",
            providerKind: .deepInfra,
            detail: "Hosted open models",
            isCustom: false
        ),
        .init(
            id: "minimax",
            name: "MiniMax",
            baseURL: "https://api.minimax.io/v1",
            defaultModel: "MiniMax-M3",
            providerKind: .miniMax,
            detail: "MiniMax OpenAI-compatible API",
            isCustom: false
        ),
        .init(
            id: "zai",
            name: "Z.AI",
            baseURL: "https://api.z.ai/api/paas/v4",
            defaultModel: "",
            providerKind: .zAI,
            detail: "GLM API",
            isCustom: false
        ),
        .init(
            id: "moonshot",
            name: "Moonshot AI",
            baseURL: "https://api.moonshot.ai/v1",
            defaultModel: "kimi-k2.5",
            providerKind: .openAICompatible,
            detail: "Kimi API",
            isCustom: false
        ),
        .init(
            id: "siliconflow",
            name: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Hosted models in China",
            isCustom: false
        ),
        .init(
            id: "ollama",
            name: "Ollama",
            baseURL: "http://localhost:11434/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Local models on Ollama",
            isCustom: false
        ),
        .init(
            id: "lm-studio",
            name: "LM Studio",
            baseURL: "http://localhost:1234/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Local models in LM Studio",
            isCustom: false
        ),
        .init(
            id: "llama-cpp",
            name: "llama.cpp",
            baseURL: "http://localhost:8080/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Local llama-server / GGUF models",
            isCustom: false
        ),
        .init(
            id: "localai",
            name: "LocalAI",
            baseURL: "http://localhost:8080/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Local OpenAI-compatible runtime",
            isCustom: false
        ),
        .init(
            id: "vllm",
            name: "vLLM",
            baseURL: "http://localhost:8000/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "High-throughput local model server",
            isCustom: false
        ),
        .init(
            id: "jan",
            name: "Jan",
            baseURL: "http://127.0.0.1:1337/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Jan local API powered by llama.cpp",
            isCustom: false
        ),
        .init(
            id: "litellm",
            name: "LiteLLM",
            baseURL: "http://localhost:4000/v1",
            defaultModel: "",
            providerKind: .openAICompatible,
            detail: "Local multi-provider proxy",
            isCustom: false
        ),
    ]

    static let all: [LLMProviderPreset] = presets + [custom]

    static func matching(_ profile: LLMProviderProfile) -> LLMProviderPreset? {
        let candidates = all.filter { preset in
            !preset.isCustom
                && preset.providerKind == profile.provider
                && preset.baseURL.caseInsensitiveCompare(profile.normalizedBaseURL) == .orderedSame
        }
        return candidates.first { $0.defaultPrefix == profile.normalizedPrefix }
            ?? candidates.first
    }
}

extension String {
    var providerPrefix: String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalarValue = value.unicodeScalars.map { scalar -> Character in
            let isASCIIAlphaNumeric = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 122)
            if isASCIIAlphaNumeric { return Character(String(scalar)) }
            return "-"
        }
        var result = String(scalarValue)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "provider" : trimmed
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
            model: newProvider.defaultModel,
            openRouterRouting: newProvider == .openRouter
                ? LLMOpenRouterRouting(enabled: true, sort: .latency)
                : .init()
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
    case skillSelection
    case chat
    case graphExtraction
    case graphQueryUnderstanding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translation: "Translation"
        case .subtitleProcessing: "Subtitle cleanup"
        case .skillSelection: "Knowledge skill selection"
        case .chat: "AI editing chat"
        case .graphExtraction: "Graph extraction & ingestion"
        case .graphQueryUnderstanding: "Graph query understanding"
        }
    }

    var detail: String {
        switch self {
        case .translation: "Translates timed subtitle cues."
        case .subtitleProcessing: "Segments subtitle cues and cleans up punctuation when supported."
        case .skillSelection: "Routes knowledge-base questions with a bounded, low-latency selector."
        case .chat: "Plans and applies edits from the editor's left chat panel."
        case .graphExtraction: "Extracts a bounded entity and relation graph from indexed transcript chunks."
        case .graphQueryUnderstanding: "Finds graph entities for knowledge-base recall."
        }
    }

    /// Selector calls are deliberately bounded and do not need a reasoning
    /// budget. These defaults are applied by both BYOK and hosted transports.
    var defaultMaxOutputTokens: Int? {
        self == .skillSelection ? 256 : nil
    }

    /// Hosted selector cannot inspect the server-side model. Send `minimal`
    /// because reasoning-required models reject `none`.
    var defaultReasoningEffort: LLMReasoningEffort? {
        self == .skillSelection ? .minimal : nil
    }
}

enum LLMReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xHigh = "xhigh"
    case max

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xHigh: "X High"
        case .max: "Max"
        }
    }
}

extension LLMReasoningEffort {
    /// OpenRouter and other gateways use `vendor/model` ids. Capability checks
    /// must look at the leaf model name.
    static func leafModelName(_ modelName: String) -> String {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    /// Returns the effort values that the chat picker can safely expose for a
    /// configured model. Known agent models reuse the same provider/model
    /// capability table as the editor agent; custom provider models remain
    /// configurable and therefore keep the full generic set.
    static func supportedChatEfforts(providerPrefix: String, modelName: String) -> [Self] {
        let normalizedPrefix = providerPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let modelCandidates = [
            normalizedModel,
            leafModelName(modelName),
        ]

        if let knownModel = modelCandidates.compactMap(AgentModel.persisted).first {
            return knownModel.supportedReasoningEfforts.compactMap { Self(rawValue: $0.rawValue) }
        }

        if modelCandidates.contains(where: { ClaudeChatModelID($0) != nil }) {
            return [.low, .medium, .high, .xHigh, .max]
        }

        // Anthropic's adaptive thinking API does not support the disabled or
        // minimal modes exposed by OpenAI-compatible providers.
        if normalizedPrefix == "anthropic"
            || normalizedModel.hasPrefix("claude-") {
            return [.low, .medium, .high, .xHigh, .max]
        }

        return allCases
    }

    static func lowestEffort(providerPrefix: String, modelName: String) -> Self {
        let supported = supportedChatEfforts(providerPrefix: providerPrefix, modelName: modelName)
        if supported.contains(.none) { return .none }
        return supported.first ?? .minimal
    }

    /// GPT-5+ OpenAI chat models reject non-default temperature. Other
    /// providers (Gemini, MiniMax, DeepSeek) still accept `temperature=0`.
    static func supportsCustomTemperature(providerPrefix _: String, modelName: String) -> Bool {
        OpenAIChatModelID(leafModelName(modelName)) == nil
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
        case .skillSelection:
            LLMRequestPolicy(
                timeoutSeconds: 8,
                maximumAttemptsPerModel: 1,
                initialBackoffSeconds: 0
            )
        case .chat:
            LLMRequestPolicy(
                timeoutSeconds: 60,
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.5
            )
        case .graphExtraction:
            LLMRequestPolicy(
                timeoutSeconds: 90,
                maximumAttemptsPerModel: 2,
                initialBackoffSeconds: 0.75
            )
        case .graphQueryUnderstanding:
            LLMRequestPolicy(
                timeoutSeconds: 15,
                maximumAttemptsPerModel: 1,
                initialBackoffSeconds: 0.5
            )
        }
    }

    static func minimumTimeoutSeconds(for useCase: LLMUseCase) -> Double {
        switch useCase {
        case .subtitleProcessing, .graphExtraction: 90
        case .translation: 45
        case .skillSelection: 3
        case .chat, .graphQueryUnderstanding: 15
        }
    }

    func validated() throws -> LLMRequestPolicy {
        try validated(for: .chat)
    }

    func validated(for useCase: LLMUseCase) throws -> LLMRequestPolicy {
        guard timeoutSeconds.isFinite, (3...1_800).contains(timeoutSeconds) else {
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
                fallbackModels: [],
                policy: .default(for: useCase)
            )
        case .skillSelection:
            LLMModelRoute(
                primaryModel: "openai/gpt-5.4-nano",
                fallbackModels: [],
                policy: .default(for: useCase)
            )
        case .subtitleProcessing:
            LLMModelRoute(
                primaryModel: "openai/gpt-5.6-luna",
                fallbackModels: [],
                policy: .default(for: useCase)
            )
        case .chat:
            LLMModelRoute(
                primaryModel: "",
                fallbackModels: ["openai/gpt-5.4-nano"],
                policy: .default(for: useCase)
            )
        case .graphExtraction:
            LLMModelRoute(
                primaryModel: "",
                fallbackModels: ["openai/gpt-5.4-nano"],
                policy: .default(for: useCase)
            )
        case .graphQueryUnderstanding:
            LLMModelRoute(
                primaryModel: "",
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

struct LLMChatModelOption: Identifiable, Equatable, Sendable {
    let reference: String
    let provider: LLMProviderKind
    let providerName: String
    let modelName: String
    let isAvailable: Bool
    let supportedReasoningEfforts: [LLMReasoningEffort]

    init(
        reference: String,
        provider: LLMProviderKind,
        providerName: String,
        modelName: String,
        isAvailable: Bool,
        supportedReasoningEfforts: [LLMReasoningEffort]
    ) {
        self.reference = reference
        self.provider = provider
        self.providerName = providerName
        self.modelName = modelName
        self.isAvailable = isAvailable
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }

    var id: String { reference.lowercased() }
}

struct LLMRuntimeConfiguration: Sendable {
    let profile: LLMProviderProfile
    let modelIdentifier: String
    let modelName: String
    let endpoint: URL
    let apiKey: String
    let useCase: LLMUseCase?
    let reasoningEffort: LLMReasoningEffort?

    init(
        profile: LLMProviderProfile,
        modelIdentifier: String,
        modelName: String,
        endpoint: URL,
        apiKey: String,
        useCase: LLMUseCase? = nil,
        reasoningEffort: LLMReasoningEffort? = nil
    ) {
        self.profile = profile
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.useCase = useCase
        self.reasoningEffort = reasoningEffort
    }

    var diagnosticDescription: String {
        let host = endpoint.host ?? "unknown"
        let extra = LLMJSONValue.compactLogObject(resolvedExtraBody)
        return "model=\(modelIdentifier) provider=\(profile.normalizedPrefix) host=\(host) extra=\(extra)"
    }

    var lowestReasoningEffort: LLMReasoningEffort {
        LLMReasoningEffort.lowestEffort(
            providerPrefix: profile.normalizedPrefix,
            modelName: modelName
        )
    }

    var openAICompatibleRequestOptions: LLMOpenAICompatibleRequestOptions {
        var options = providerRequestOptions
        if useCase == .chat, let reasoningEffort {
            options.reasoningEffort = reasoningEffort.rawValue
        }
        switch useCase {
        case .skillSelection:
            applyStructuredOutputConstraints(to: &options)
            options.maxOutputTokens = 256
        case .subtitleProcessing:
            applyStructuredOutputConstraints(to: &options)
            options.maxOutputTokens = 4_096
        case .translation:
            applyStructuredOutputConstraints(to: &options)
            options.maxOutputTokens = 8_192
        case .chat, .graphExtraction, .graphQueryUnderstanding, .none:
            break
        }
        return options
    }

    private var providerRequestOptions: LLMOpenAICompatibleRequestOptions {
        let normalizedModel = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if isMiniMaxProvider {
            return LLMOpenAICompatibleRequestOptions(
                reasoningSplit: true,
                thinkingType: normalizedModel == "minimax-m3" ? "disabled" : nil
            )
        }

        // DeepSeek V4 defaults to thinking mode with high effort. Structured
        // subtitle/translation completions wait for the full non-streaming
        // response, so leave thinking disabled unless the caller opts in.
        if isDeepSeekProvider {
            return LLMOpenAICompatibleRequestOptions(thinkingType: "disabled")
        }

        return .init()
    }

    private func applyStructuredOutputConstraints(
        to options: inout LLMOpenAICompatibleRequestOptions
    ) {
        if isMiniMaxProvider || isDeepSeekProvider {
            if supportsCustomTemperature {
                options.temperature = 0
            }
            return
        }
        if isGeminiFamily {
            options.thinkingType = "disabled"
            options.reasoningEnabled = false
            options.reasoningEffort = nil
            options.temperature = 0
            return
        }
        options.thinkingType = nil
        options.reasoningEnabled = nil
        options.reasoningEffort = lowestReasoningEffort.rawValue
        if supportsCustomTemperature {
            options.temperature = 0
        }
    }

    private var supportsCustomTemperature: Bool {
        LLMReasoningEffort.supportsCustomTemperature(
            providerPrefix: profile.normalizedPrefix,
            modelName: modelName
        )
    }

    private var isMiniMaxProvider: Bool {
        let host = endpoint.host?.lowercased() ?? ""
        return profile.provider == .miniMax
            || profile.normalizedPrefix == LLMProviderKind.miniMax.defaultPrefix
            || host.hasSuffix("minimax.io")
    }

    private var isDeepSeekProvider: Bool {
        let host = endpoint.host?.lowercased() ?? ""
        let normalizedModel = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return profile.normalizedPrefix.caseInsensitiveCompare("deepseek") == .orderedSame
            || host.contains("deepseek.com")
            || normalizedModel.hasPrefix("deepseek-")
    }

    private var isGeminiFamily: Bool {
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

    var diagnosticDescription: String {
        let routes = configurations.map(\.diagnosticDescription).joined(separator: " | ")
        return "use_case=\(useCase.rawValue) timeout_s=\(Int(policy.timeoutSeconds)) attempts=\(policy.maximumAttemptsPerModel) routes=\(configurations.count) [\(routes)]"
    }
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
            "Complete the AI service setup before continuing."
        case .invalidModelReference:
            "The AI service setup is invalid. Review the connection settings."
        case .missingProvider:
            "The selected AI service is no longer available. Review the connection settings."
        case .missingAPIKey:
            "Add an API key in Settings > AI before running this flow."
        case .noConfiguredModel(let useCase):
            "Configure an API key and an available AI service for \(useCase.title.lowercased())."
        case .invalidTimeout:
            "Set timeout between 3 and 1,800 seconds."
        case .invalidRetryCount:
            "Set retry attempts between 1 and 4."
        case .invalidBackoff:
            "Set initial retry delay between 0 and 10 seconds."
        case .cannotRemoveLastProvider:
            "Keep at least one LLM provider."
        }
    }
}

extension String {
    var normalizedModelReference: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    private static let useBYOKKey = "voxella.llm.use-byok.v1"
    private static let chatReasoningEffortKey = "voxella.llm.chat-reasoning-effort.v1"
    private static let useBYOKMigrationKey = "voxella.llm.migration.use-byok.v1"
    private static let defaultMiniMaxProviderMigrationKey = "voxella.llm.migration.remove-default-minimax-provider.v2"
    private static let legacyDefaultMiniMaxProviderMigrationKey = "voxella.llm.migration.remove-default-minimax-provider.v1"
    private static let credentialAvailabilityDefaultsKey = "voxella.llm.credential-availability.v1"

    private(set) var providers: [LLMProviderProfile]
    private(set) var routes: [LLMUseCase: LLMModelRoute]
    private(set) var credentialAvailability: [UUID: Bool] = [:]
    private(set) var credentialSaveStates: [UUID: LLMAPIKeySaveState] = [:]
    private(set) var credentialError: String?
    private(set) var configurationError: String?

    var chatReasoningEffort: LLMReasoningEffort {
        didSet {
            defaults.set(chatReasoningEffort.rawValue, forKey: Self.chatReasoningEffortKey)
            guard oldValue != chatReasoningEffort else { return }
            notifyConfigurationChanged()
        }
    }

    var useBYOK: Bool {
        didSet {
            defaults.set(useBYOK, forKey: Self.useBYOKKey)
            defaults.set(true, forKey: Self.useBYOKMigrationKey)
            guard oldValue != useBYOK else { return }
            notifyConfigurationChanged()
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
        self.chatReasoningEffort = defaults.string(forKey: Self.chatReasoningEffortKey)
            .flatMap(LLMReasoningEffort.init(rawValue:))
            ?? .medium
        var shouldPersist = false

        switch Self.loadConfiguration(from: defaults) {
        case .valid(let saved):
            providers = saved.providers
            routes = saved.routes
        case .invalid:
            providers = [.defaultOpenAI]
            routes = Self.defaultRoutes
            configurationError = L10n.string("Saved AI settings could not be read. They were left unchanged.")
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
                providers = [.defaultOpenAI]
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
        if migrateDefaultMiniMaxProviderIfNeeded() {
            shouldPersist = true
        }
        if normalizeRoutesForProviderRouting() {
            shouldPersist = true
        }
        if shouldPersist, configurationError == nil {
            persist()
        }
        restoreCredentialAvailability()
    }

    func provider(id: UUID) -> LLMProviderProfile? {
        providers.first { $0.id == id }
    }

    func route(for useCase: LLMUseCase) -> LLMModelRoute {
        routes[useCase] ?? .default(for: useCase)
    }

    /// Chat models exposed by the composer follow the same provider-aware
    /// catalog as the editor agent:
    ///
    /// - explicitly configured LLM OpenAI/Claude providers use only their
    ///   chat-capable models (OpenAI 5.6+ and Claude 4.8+);
    /// - when neither provider is configured, only the primary model from the
    ///   AI Service's “AI editing chat” route is exposed.
    var chatModelOptions: [LLMChatModelOption] {
        let providerProfiles = providers.compactMap { profile -> (LLMProviderProfile, AgentProvider)? in
            guard let provider = chatProvider(for: profile) else { return nil }
            return (profile, provider)
        }
        if !providerProfiles.isEmpty {
            return uniqueChatModelOptions(providerProfiles.flatMap { profile, provider in
                chatModelOptions(for: profile, provider: provider)
            })
        }

        guard let fallback = chatModelOption(for: route(for: .chat).primaryModel) else {
            return []
        }
        return [fallback]
    }

    var effectiveChatModelOption: LLMChatModelOption? {
        let options = chatModelOptions
        let selectedReference = route(for: .chat).primaryModel.normalizedModelReference
        return options.first(where: { $0.id == selectedReference }) ?? options.first
    }

    var effectiveChatModelReference: String {
        effectiveChatModelOption?.reference ?? route(for: .chat).primaryModel
    }

    var chatReasoningEffortsForCurrentModel: [LLMReasoningEffort] {
        return effectiveChatModelOption?.supportedReasoningEfforts
            ?? LLMReasoningEffort.allCases
    }

    var effectiveChatReasoningEffort: LLMReasoningEffort {
        let supported = chatReasoningEffortsForCurrentModel
        guard supported.contains(chatReasoningEffort) else {
            return supported.contains(.medium) ? .medium : (supported.first ?? .medium)
        }
        return chatReasoningEffort
    }

    /// Selects a model from the composer catalog and promotes it to the
    /// primary model in the AI Service's chat route. Existing route fallbacks
    /// remain intact.
    func selectChatModel(_ option: LLMChatModelOption) {
        selectChatModel(reference: option.reference)
    }

    func selectChatModel(reference: String) {
        guard let selected = chatModelOptions.first(where: {
            $0.id == reference.normalizedModelReference
        }) else { return }

        let currentRoute = route(for: .chat)
        let selectedReference = selected.reference
        let selectedID = selectedReference.normalizedModelReference
        let references = [selectedReference] + currentRoute.modelChain.filter {
            $0.normalizedModelReference != selectedID
        }
        let nextRoute = LLMModelRoute(
            primaryModel: references[0],
            fallbackModels: Array(references.dropFirst()),
            policy: currentRoute.policy
        )

        do {
            try updateRoute(nextRoute, for: .chat)
            synchronizeChatReasoningEffort()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func synchronizeChatReasoningEffort() {
        let effective = effectiveChatReasoningEffort
        guard effective != chatReasoningEffort else { return }
        chatReasoningEffort = effective
    }

    /// Repairs a persisted selection when a provider key is added/removed or
    /// when an older model no longer belongs to the filtered chat catalog.
    func synchronizeChatModelSelection() {
        guard let selected = effectiveChatModelOption else { return }
        if route(for: .chat).primaryModel.normalizedModelReference != selected.id {
            selectChatModel(selected)
            return
        }
        synchronizeChatReasoningEffort()
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        credentialAvailability[providerID] == true
    }

    func apiKeySaveState(for providerID: UUID) -> LLMAPIKeySaveState {
        credentialSaveStates[providerID] ?? .idle
    }

    func hasConfiguredModel(for useCase: LLMUseCase) -> Bool {
        return route(for: useCase).modelChain.contains { reference in
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
            model: kind.defaultModel,
            openRouterRouting: kind == .openRouter
                ? LLMOpenRouterRouting(enabled: true, sort: .latency)
                : .init()
        )
        providers.append(profile)
        persist()
        credentialAvailability[profile.id] = false
        persistCredentialAvailability()
        notifyConfigurationChanged()
        return profile.id
    }

    @discardableResult
    func addProvider(preset: LLMProviderPreset) -> UUID {
        let prefix = uniquePrefix(basedOn: preset.defaultPrefix)
        let profile = LLMProviderProfile(
            provider: preset.providerKind,
            prefix: prefix,
            displayName: preset.name,
            baseURL: preset.baseURL,
            model: preset.defaultModel,
            openRouterRouting: preset.providerKind == .openRouter
                ? LLMOpenRouterRouting(enabled: true, sort: .latency)
                : .init()
        )
        providers.append(profile)
        persist()
        credentialAvailability[profile.id] = false
        persistCredentialAvailability()
        notifyConfigurationChanged()
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
        notifyConfigurationChanged()
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
        credentialSaveStates[id] = nil
        credentialSaveGeneration[id] = nil
        persist()
        persistCredentialAvailability()
        notifyConfigurationChanged()
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
        notifyConfigurationChanged()
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
                } catch let error as KeychainStoreError where error == .temporarilyUnavailable || error == .configurationError || error == .corrupted {
                    statuses[profile.id] = credentialAvailability[profile.id] ?? false
                    statusError = error.localizedDescription
                } catch {
                    statuses[profile.id] = false
                    statusError = error.localizedDescription
                }
            }
            guard generation == credentialGeneration else { return }
            let availabilityChanged = credentialAvailability != statuses
            credentialAvailability = statuses
            credentialError = statusError
            persistCredentialAvailability()
            if availabilityChanged {
                notifyConfigurationChanged()
            }
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
            } catch let error as KeychainStoreError where error == .temporarilyUnavailable || error == .configurationError || error == .corrupted {
                statuses[profile.id] = credentialAvailability[profile.id] ?? false
                statusError = error.localizedDescription
            } catch {
                statuses[profile.id] = false
                statusError = error.localizedDescription
            }
        }
        guard generation == credentialGeneration else { return hasAPIKey }
        let availabilityChanged = credentialAvailability != statuses
        credentialAvailability = statuses
        credentialError = statusError
        persistCredentialAvailability()
        if availabilityChanged {
            notifyConfigurationChanged()
        }
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
        let availabilityChanged = credentialAvailability[providerID] != true
        credentialAvailability[providerID] = true
        persistCredentialAvailability()
        credentialError = nil
        if availabilityChanged {
            notifyConfigurationChanged()
        }
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
        let availabilityChanged = credentialAvailability[providerID] != false
        credentialAvailability[providerID] = false
        persistCredentialAvailability()
        credentialSaveStates[providerID] = .idle
        credentialError = nil
        if availabilityChanged {
            notifyConfigurationChanged()
        }
    }

    private func loadCredential(for profile: LLMProviderProfile) async throws -> String? {
        try await Task.detached(priority: .utility) {
            try Self.loadCredentialSynchronously(for: profile)
        }.value
    }

    private nonisolated static func loadCredentialSynchronously(for profile: LLMProviderProfile) throws -> String? {
        try KeychainStore.loadProtected(account: profile.credentialAccount).get()
    }

    private func restoreCredentialAvailability() {
        let cached = defaults.dictionary(forKey: Self.credentialAvailabilityDefaultsKey) ?? [:]
        credentialAvailability = Dictionary(
            providers.map { profile in
                (profile.id, cached[profile.id.uuidString] as? Bool ?? false)
            },
            uniquingKeysWith: { current, _ in current }
        )
    }

    private func persistCredentialAvailability() {
        let cached = Dictionary(
            providers.map { profile in
                (profile.id.uuidString, credentialAvailability[profile.id] == true)
            },
            uniquingKeysWith: { current, _ in current }
        )
        defaults.set(cached, forKey: Self.credentialAvailabilityDefaultsKey)
    }

    private func notifyConfigurationChanged() {
        NotificationCenter.default.post(name: .aiConfigurationDidChange, object: nil)
    }

    func runtimeRoute(for useCase: LLMUseCase) async throws -> LLMRuntimeRoute {
        let route = route(for: useCase)
        let policy = try route.policy.validated(for: useCase)
        let reasoningEffort = useCase == .chat ? effectiveChatReasoningEffort : nil
        var configurations: [LLMRuntimeConfiguration] = []
        var firstCredentialError: Error?

        for reference in route.modelChain {
            let parsed = try Self.parseModelReference(reference)
            guard let profile = providers.first(where: {
                $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
            }) else {
                Log.llm.warning(
                    "byok route skip use_case=\(useCase.rawValue) model=\(reference) reason=missing_provider"
                )
                continue
            }
            let validated = try profile.validated()
            do {
                guard let key = try await loadCredential(for: validated) else {
                    Log.llm.warning(
                        "byok route skip use_case=\(useCase.rawValue) model=\(reference) provider=\(validated.normalizedPrefix) reason=missing_api_key"
                    )
                    continue
                }
                configurations.append(LLMRuntimeConfiguration(
                    profile: validated,
                    modelIdentifier: "\(validated.normalizedPrefix)/\(parsed.model)",
                    modelName: parsed.model,
                    endpoint: try validated.completionEndpoint(),
                    apiKey: key,
                    useCase: useCase,
                    reasoningEffort: reasoningEffort
                ))
            } catch {
                Log.llm.warning(
                    "byok route skip use_case=\(useCase.rawValue) model=\(reference) provider=\(validated.normalizedPrefix) reason=credential_error error=\(LLMDiagnostics.description(error))"
                )
                firstCredentialError = firstCredentialError ?? error
            }
        }

        if configurations.isEmpty {
            Log.llm.warning(
                "byok route empty use_case=\(useCase.rawValue) models=\(route.modelChain.joined(separator: ","))"
            )
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

    private func chatModelOption(for reference: String) -> LLMChatModelOption? {
        guard let parsed = try? Self.parseModelReference(reference),
              let profile = providers.first(where: {
                  $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
              }) else {
            return nil
        }

        let canonicalReference = effectiveModelReference(
            "\(profile.normalizedPrefix)/\(parsed.model)"
        )
        guard let canonical = try? Self.parseModelReference(canonicalReference) else {
            return nil
        }
        return LLMChatModelOption(
            reference: canonicalReference,
            provider: profile.provider,
            providerName: profile.normalizedDisplayName,
            modelName: canonical.model,
            isAvailable: hasAPIKey(for: profile.id),
            supportedReasoningEfforts: LLMReasoningEffort.supportedChatEfforts(
                providerPrefix: profile.normalizedPrefix,
                modelName: canonical.model
            )
        )
    }

    private func chatModelOptions(
        for profile: LLMProviderProfile,
        provider: AgentProvider
    ) -> [LLMChatModelOption] {
        chatModels(for: provider, profile: profile).map { model in
            let reference = profile.normalizedPrefix + "/" + model.rawValue
            return LLMChatModelOption(
                reference: reference,
                provider: profile.provider,
                providerName: profile.normalizedDisplayName,
                modelName: model.rawValue,
                isAvailable: hasAPIKey(for: profile.id),
                supportedReasoningEfforts: model.supportedReasoningEfforts.compactMap {
                    LLMReasoningEffort(rawValue: $0.rawValue)
                }
            )
        }
    }

    private func uniqueChatModelOptions(
        _ options: [LLMChatModelOption]
    ) -> [LLMChatModelOption] {
        var seen: Set<String> = []
        return options.filter { seen.insert($0.id).inserted }
    }

    private func chatModels(
        for provider: AgentProvider,
        profile: LLMProviderProfile
    ) -> [AgentModel] {
        let references = [profile.defaultModelReference].compactMap { $0 }
            + route(for: .chat).modelChain
        return chatModels(for: provider, references: references, profile: profile)
    }

    private func chatModels(
        for provider: AgentProvider,
        references: [String],
        profile: LLMProviderProfile? = nil
    ) -> [AgentModel] {
        var result = AgentModel.chatModels(for: provider)
        let candidates = references.compactMap { reference -> AgentModel? in
            guard let parsed = try? Self.parseModelReference(reference) else { return nil }
            if let profile {
                guard parsed.prefix.caseInsensitiveCompare(profile.normalizedPrefix) == .orderedSame else {
                    return nil
                }
            } else {
                guard let referenceProfile = providers.first(where: {
                    $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                }), chatProvider(for: referenceProfile) == provider else {
                    return nil
                }
            }

            switch provider {
            case .openAI:
                return OpenAIChatModelID(parsed.model).map { AgentModel(rawValue: $0.rawValue) }
            case .anthropic:
                return ClaudeChatModelID(parsed.model).map { AgentModel(rawValue: $0.rawValue) }
            }
        }
        for candidate in candidates where !result.contains(where: {
            $0.rawValue.caseInsensitiveCompare(candidate.rawValue) == .orderedSame
        }) {
            result.append(candidate)
        }
        return result
    }

    private func chatProvider(for profile: LLMProviderProfile) -> AgentProvider? {
        let prefix = profile.normalizedPrefix
        if profile.provider == .openAI || prefix == "openai" {
            return .openAI
        }
        if prefix == "claude" || prefix == "anthropic" {
            return .anthropic
        }
        return nil
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
        return result
    }

    @discardableResult
    private func migrateDefaultMiniMaxProviderIfNeeded() -> Bool {
        let wasPreviousMigrationApplied = defaults.bool(
            forKey: Self.legacyDefaultMiniMaxProviderMigrationKey
        )
        guard !defaults.bool(forKey: Self.defaultMiniMaxProviderMigrationKey) else { return false }
        defaults.set(true, forKey: Self.defaultMiniMaxProviderMigrationKey)

        let defaultMiniMax = LLMProviderProfile.defaultMiniMax
        let defaultOpenAI = LLMProviderProfile.defaultOpenAI
        var changed = false
        guard providers.count == 2,
              providers.contains(where: { $0 == defaultOpenAI }),
              let index = providers.firstIndex(where: { $0 == defaultMiniMax }) else {
            guard wasPreviousMigrationApplied,
                  providers.count == 1,
                  providers[0] == defaultOpenAI else {
                return false
            }
            return migrateRoutesAfterPreviousDefaultMigration()
        }

        providers.remove(at: index)
        if providers.isEmpty {
            providers = [defaultOpenAI]
        }
        changed = true

        guard let retiredReference = defaultMiniMax.defaultModelReference?.normalizedModelReference else {
            return changed
        }
        for useCase in LLMUseCase.allCases {
            guard let route = routes[useCase] else { continue }
            let primaryWasRetired = route.primaryModel.normalizedModelReference == retiredReference
            let fallbackModels = route.fallbackModels.filter {
                $0.normalizedModelReference != retiredReference
            }
            guard primaryWasRetired || fallbackModels != route.fallbackModels else { continue }
            routes[useCase] = LLMModelRoute(
                primaryModel: primaryWasRetired ? "" : route.primaryModel,
                fallbackModels: fallbackModels,
                policy: route.policy
            )
            changed = true
        }
        return changed
    }

    private func migrateRoutesAfterPreviousDefaultMigration() -> Bool {
        let openAIReference = "openai/gpt-5.4-nano"
        let subtitleReference = "openai/gpt-5.6-luna"
        var changed = false

        for useCase in LLMUseCase.allCases {
            guard let route = routes[useCase] else { continue }
            switch useCase {
            case .subtitleProcessing:
                guard route.primaryModel.normalizedModelReference == subtitleReference,
                      route.fallbackModels.map(\.normalizedModelReference) == [openAIReference] else {
                    continue
                }
                routes[useCase] = LLMModelRoute(
                    primaryModel: route.primaryModel,
                    fallbackModels: [],
                    policy: route.policy
                )
                changed = true
            case .chat, .graphExtraction, .graphQueryUnderstanding:
                guard route.primaryModel.normalizedModelReference == openAIReference,
                      route.fallbackModels.isEmpty else {
                    continue
                }
                routes[useCase] = LLMModelRoute(
                    primaryModel: "",
                    fallbackModels: [route.primaryModel],
                    policy: route.policy
                )
                changed = true
            case .translation, .skillSelection:
                continue
            }
        }
        return changed
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
        var changed = false
        for index in providers.indices where providers[index].isOpenRouter {
            let routing = providers[index].openRouterRouting
            guard routing.order.isEmpty else { continue }
            let hasNitroRoute = routes.values
                .flatMap(\.modelChain)
                .contains { reference in
                    guard let parsed = try? Self.parseModelReference(reference),
                          parsed.prefix.caseInsensitiveCompare(providers[index].normalizedPrefix) == .orderedSame
                    else { return false }
                    return parsed.model.lowercased().hasSuffix(":nitro")
                }
            guard (!routing.enabled && routing.sort == nil)
                || (routing.sort == .throughput && hasNitroRoute) else {
                continue
            }
            providers[index].openRouterRouting = LLMOpenRouterRouting(
                enabled: true,
                order: [],
                allowFallbacks: routing.allowFallbacks,
                sort: .latency
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

        let model = Self.removingNitroVariant(from: parsed.model)
        return "\(parsed.prefix)/\(model)"
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
        }.value
    }
}
