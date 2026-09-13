import Foundation

extension Notification.Name {
    static let agentAPIKeyChanged = Notification.Name("agentAPIKeyChanged")
}

enum AgentProvider: String, CaseIterable, Sendable {
    case anthropic
    case openAI

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    private var credentialStorage: (account: String, environment: String) {
        switch self {
        case .anthropic: ("anthropic-api-key", "ANTHROPIC_API_KEY")
        case .openAI: ("openai-api-key", "OPENAI_API_KEY")
        }
    }

    fileprivate var storedAPIKey: String {
        #if DEBUG
        let environmentValue = ProcessInfo.processInfo.environment[credentialStorage.environment]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentValue.isEmpty { return environmentValue }
        #endif
        return KeychainStore.load(account: credentialStorage.account) ?? ""
    }

    @concurrent
    func loadAPIKey() async -> String {
        storedAPIKey
    }

    @concurrent
    func setAPIKey(_ key: String?) async {
        if let key {
            KeychainStore.save(key, account: credentialStorage.account)
        } else {
            KeychainStore.delete(account: credentialStorage.account)
        }
        NotificationCenter.default.post(name: .agentAPIKeyChanged, object: rawValue)
    }
}

enum AgentReasoningEffort: String, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xHigh = "xhigh"
    case max

    var labelKey: String {
        switch self {
        case .none: L10n.key("None")
        case .minimal: L10n.key("Minimal")
        case .low: L10n.key("Low")
        case .medium: L10n.key("Medium")
        case .high: L10n.key("High")
        case .xHigh: L10n.key("X High")
        case .max: L10n.key("Max")
        }
    }
}

struct AgentModel: Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let sonnet5 = AgentModel(rawValue: "claude-sonnet-5")
    static let opus5 = AgentModel(rawValue: "claude-opus-5")
    static let fable5 = AgentModel(rawValue: "claude-fable-5")
    static let luna = AgentModel(rawValue: "gpt-5.6-luna")
    static let terra = AgentModel(rawValue: "gpt-5.6-terra")
    static let sol = AgentModel(rawValue: "gpt-5.6-sol")

    static let allCases = [sonnet5, opus5, fable5, luna, terra, sol]
    static let anthropicModels = [sonnet5, opus5, fable5]

    static let defaultModel: AgentModel = .terra

    var displayName: String {
        switch rawValue {
        case Self.sonnet5.rawValue: "Sonnet 5"
        case Self.opus5.rawValue: "Opus 5"
        case Self.fable5.rawValue: "Fable 5"
        case Self.luna.rawValue: "GPT-5.6 Luna"
        case Self.terra.rawValue: "GPT-5.6 Terra"
        case Self.sol.rawValue: "GPT-5.6 Sol"
        default:
            rawValue
        }
    }

    var provider: AgentProvider {
        rawValue.hasPrefix("claude-") ? .anthropic : .openAI
    }

    var maxOutputTokens: Int { 64_000 }

    var requiresPaidHostedPlan: Bool {
        self == .fable5 || self == .sol
    }

    static func persisted(_ rawValue: String) -> AgentModel? {
        if rawValue == "claude-opus-4-8" { return .opus5 }
        if let model = allCases.first(where: { $0.rawValue == rawValue }) { return model }
        return OpenAIChatModelID(rawValue).map { AgentModel(rawValue: $0.rawValue) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let model = Self.persisted(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported agent model"
            )
        }
        self = model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var supportedReasoningEfforts: [AgentReasoningEffort] {
        switch provider {
        case .anthropic:
            [.low, .medium, .high, .xHigh, .max]
        case .openAI:
            OpenAIChatModelID(rawValue)?.supportedReasoningEfforts ?? []
        }
    }

}

struct OpenAIChatModelID: Hashable, Sendable {
    let rawValue: String
    let majorVersion: Int
    let minorVersion: Int

    init?(_ rawValue: String) {
        let components = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        let version = components.count > 1
            ? components[1].split(separator: ".", omittingEmptySubsequences: false)
            : []
        guard components.count >= 2,
              components[0] == "gpt",
              !components.dropFirst(2).contains(where: { $0.isEmpty }),
              version.count <= 2,
              let major = Int(version[0]),
              major >= 5
        else { return nil }

        let minor = version.count == 2 ? Int(version[1]) : 0
        guard let minor,
              components.dropFirst(2).allSatisfy({ $0.allSatisfy(\.isLetter) }),
              major > 5 || minor >= 6
        else { return nil }

        self.rawValue = rawValue
        self.majorVersion = major
        self.minorVersion = minor
    }

    var supportedReasoningEfforts: [AgentReasoningEffort] {
        if majorVersion == 5, minorVersion == 6 {
            [.none, .low, .medium, .high, .xHigh, .max]
        } else {
            [.low, .medium, .high, .xHigh, .max]
        }
    }
}

enum OpenAIModelDiscovery {
    private struct Response: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }

    @concurrent
    static func fetch(apiKey: String) async throws -> [AgentModel] {
        guard !apiKey.isEmpty else { return [] }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AgentClientTransportError.httpError(
                provider: .openAI,
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        return try models(from: data)
    }

    static func models(from data: Data) throws -> [AgentModel] {
        try JSONDecoder().decode(Response.self, from: data).data
            .compactMap { OpenAIChatModelID($0.id).map { AgentModel(rawValue: $0.rawValue) } }
            .sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }
}

struct AgentRunSettings: Equatable, Sendable {
    let model: AgentModel
    let reasoningEffort: AgentReasoningEffort
}

enum AgentReasoningPreferences {
    static func effort(for model: AgentModel, defaults: UserDefaults) -> AgentReasoningEffort {
        guard let rawValue = defaults.string(forKey: key("effort", model: model)),
              let effort = AgentReasoningEffort(rawValue: rawValue),
              model.supportedReasoningEfforts.contains(effort)
        else { return .medium }
        return effort
    }

    static func set(_ effort: AgentReasoningEffort, for model: AgentModel, defaults: UserDefaults) {
        defaults.set(effort.rawValue, forKey: key("effort", model: model))
    }

    private static func key(_ setting: String, model: AgentModel) -> String {
        "agentReasoning.\(setting).\(model.rawValue)"
    }
}

enum AgentRoute: Equatable, Sendable {
    case direct
    case hosted
    case unavailable
}

enum AgentRouting {
    static func route(
        model: AgentModel,
        credentials: AgentCredentialSnapshot,
        hasHostedCredits: Bool,
        hasPaidPlan: Bool
    ) -> AgentRoute {
        if !credentials[model.provider].isEmpty { return .direct }
        if model.requiresPaidHostedPlan && !hasPaidPlan { return .unavailable }
        return hasHostedCredits ? .hosted : .unavailable
    }
}

struct AgentCredentialSnapshot: Equatable, Sendable {
    private let apiKeys: [AgentProvider: String]

    init(_ apiKeys: [AgentProvider: String] = [:]) {
        self.apiKeys = apiKeys
    }

    subscript(provider: AgentProvider) -> String {
        apiKeys[provider, default: ""]
    }

    @concurrent
    static func loadFromKeychain() async -> AgentCredentialSnapshot {
        AgentCredentialSnapshot(Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map {
            ($0, $0.storedAPIKey)
        }))
    }
}

enum AgentStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AgentRequestMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [AgentRequestBlock]
}

enum AgentRequestBlock: Sendable {
    case content(AgentContentBlock)
    case image(base64: String, mediaType: String)
}

struct AgentToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct AgentRequestContext: Equatable, Sendable {
    let conversationID: UUID
    let traceID: UUID
    let spanID: UUID
    let inputMessageID: UUID
    let outputMessageID: UUID
    let projectID: String?

    func apply(to request: inout URLRequest, telemetryEnabled: Bool) {
        request.setValue(conversationID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Conversation-Id")
        request.setValue(traceID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Trace-Id")
        request.setValue(spanID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Span-Id")
        request.setValue(inputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Input-Message-Id")
        request.setValue(outputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Output-Message-Id")
        if let projectID, !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "X-Palmier-Project-Id")
        }
        request.setValue(telemetryEnabled ? "1" : "0", forHTTPHeaderField: "X-Palmier-Agent-Telemetry")
    }
}

enum AgentStreamEvent: Equatable, Sendable {
    case thinkingDelta(String)
    case thinkingSignature(String)
    case redactedThinking(String)
    case reasoningSummaryDelta(String)
    case reasoningComplete(itemID: String?, summary: String, encryptedContent: String)
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AgentStopReason)
}

enum AgentClientTransportError: LocalizedError {
    case missingAPIKey(AgentProvider)
    case insufficientCredits(String)
    case httpError(provider: AgentProvider, status: Int, body: String)
    case streamError(provider: AgentProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "No \(provider.displayName) API key is set."
        case .insufficientCredits(let message):
            message.isEmpty ? "There are not enough credits for this AI request." : message
        case .httpError(let provider, let status, let body):
            "\(provider.displayName) API error (\(status)): \(body.prefix(500))"
        case .streamError(let provider, let message):
            "\(provider.displayName) stream error: \(message)"
        }
    }
}

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

func makeAgentStream(
    _ operation: @escaping @Sendable (
        AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> Void
) -> AsyncThrowingStream<AgentStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await operation(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

enum AgentHTTP {
    static let streamIdleTimeout: TimeInterval = 600

    static func bytes(
        for request: URLRequest,
        makeError: (Int, String) -> any Error
    ) async throws -> URLSession.AsyncBytes {
        var request = request
        request.timeoutInterval = streamIdleTimeout
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode >= 400 else {
            return bytes
        }
        var body = ""
        for try await line in bytes.lines { body += line + "\n" }
        throw makeError(response.statusCode, body)
    }
}

extension AgentRunSettings {
    func requestBody(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        switch model.provider {
        case .anthropic:
            AnthropicRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        case .openAI:
            OpenAIRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        }
    }
}

extension AgentProvider {
    func parseSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        switch self {
        case .anthropic:
            try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
        case .openAI:
            try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
        }
    }
}
