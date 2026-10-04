import Foundation
import Observation

struct ChatModelCapability: Codable, Equatable, Sendable {
    enum Thinking: String, Codable, Sendable { case automatic, effort, adaptive, budget }
    let thinking: Thinking
    let efforts: [LLMReasoningEffort]
    var maxOutputTokens: Int? = nil

    static func known(_ model: String) -> Self {
        let name = LLMReasoningEffort.leafModelName(model)
        if name == LLMModelLifecycle.replacementNano {
            return .init(thinking: .effort, efforts: [.minimal, .low, .medium, .high])
        }
        if name.hasPrefix("claude-") {
            let name = name.replacingOccurrences(of: ".", with: "-")
            if name.contains("claude-3-") && !name.contains("claude-3-7-sonnet") {
                return .init(thinking: .automatic, efforts: [], maxOutputTokens: name.contains("3-5") ? 8_192 : 4_096)
            }
            if name.contains("haiku") || name.contains("-3") || name.contains("-4-5") || name.hasSuffix("-4") {
                return .init(thinking: .budget, efforts: [.none, .low, .medium, .high])
            }
            var efforts: [LLMReasoningEffort] = [.low, .medium, .high]
            if name.contains("opus") || name.contains("fable") {
                if !name.contains("-4-6") { efforts.append(.xHigh) }
                efforts.append(.max)
            }
            return .init(thinking: .adaptive, efforts: efforts)
        }
        if name.hasPrefix("gpt-6") || name.hasPrefix("gpt-5.6") {
            return .init(thinking: .effort, efforts: (name.contains("astra") ? [] : [.none]) + [.low, .medium, .high, .xHigh, .max])
        }
        if name.hasPrefix("gpt-5.5") || name.hasPrefix("gpt-5.4") || name.hasPrefix("gpt-5.2") {
            return .init(thinking: .effort, efforts: [.none, .low, .medium, .high, .xHigh])
        }
        return .init(thinking: .automatic, efforts: [])
    }

    func resolve(_ effort: LLMReasoningEffort) -> LLMReasoningEffort? {
        efforts.contains(effort) ? effort : (efforts.contains(.medium) ? .medium : efforts.first)
    }

    func applyAnthropic(to body: inout [String: Any], effort: LLMReasoningEffort?) {
        if let maxOutputTokens { body["max_tokens"] = min(body["max_tokens"] as? Int ?? maxOutputTokens, maxOutputTokens) }
        guard let effort = effort.flatMap(resolve) else { return }
        body.removeValue(forKey: "output_config")
        switch thinking {
        case .adaptive:
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort.rawValue]
        case .budget:
            if effort == .none { body["thinking"] = ["type": "disabled"]; return }
            let requestedBudget = effort == .low ? 1_024 : effort == .medium ? 4_096 : 8_192
            let budget = min(requestedBudget, max(1_024, (maxOutputTokens ?? 64_000) - 1_024))
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            body["max_tokens"] = min(maxOutputTokens ?? 64_000, max(body["max_tokens"] as? Int ?? 0, budget + 8_192))
            body.removeValue(forKey: "temperature")
        case .automatic, .effort: break
        }
    }
}

struct ProviderCatalogModel: Codable, Equatable, Sendable {
    let id: String
    let capability: ChatModelCapability
}

struct ProviderCatalogRecord: Codable, Sendable {
    let identity: String
    let fetchedAt: Date
    let models: [ProviderCatalogModel]
    var schemaVersion: Int? = 3
}

/// Only models returned by the configured provider are offered; refresh never
/// silently replaces the user's route or invents models unavailable to their key.
@Observable @MainActor
final class ProviderModelCatalog {
    static let shared = ProviderModelCatalog()
    private(set) var records: [UUID: ProviderCatalogRecord] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []
    private var generations: [UUID: UUID] = [:]
    private var identities: [UUID: String] = [:]

    func invalidate(_ providerID: UUID) {
        generations[providerID] = UUID()
        loading.remove(providerID)
        records[providerID] = nil
        errors[providerID] = nil
        identities[providerID] = nil
    }

    func models(for profile: LLMProviderProfile) -> [ProviderCatalogModel] {
        (records[profile.id]?.models ?? []).filter { !LLMModelLifecycle.isRetired($0.id) }
    }

    func capability(profile: LLMProviderProfile, model: String) -> ChatModelCapability {
        models(for: profile).first(where: { $0.id == model })?.capability ?? .known(model)
    }

    func refresh(settings: LLMSettingsStore, force: Bool = false) async {
        for profile in settings.providers where profile.agentProtocol != nil {
            let token = UUID()
            defer { if generations[profile.id] == token { loading.remove(profile.id) } }
            do {
                guard let key = try await settings.loadAPIKey(for: profile.id), !key.isEmpty else {
                    records[profile.id] = nil
                    continue
                }
                let identity = ProviderConnectionRecord.identity(profile: profile, key: key)
                if loading.contains(profile.id), identities[profile.id] == identity, !force { continue }
                generations[profile.id] = token
                identities[profile.id] = identity
                loading.insert(profile.id)
                if records[profile.id]?.identity != identity { records[profile.id] = nil }
                if records[profile.id] == nil,
                   let cached = try await ProviderStateStore.shared.load(ProviderCatalogRecord.self, providerID: profile.id, category: "models"), cached.identity == identity, cached.schemaVersion == 3 {
                    records[profile.id] = cached
                }
                if !force, let cached = records[profile.id], Date().timeIntervalSince(cached.fetchedAt) < 86_400 { continue }
                let values = try await Self.fetch(profile: profile, key: key)
                guard generations[profile.id] == token,
                      let current = settings.provider(id: profile.id),
                      let currentKey = try await settings.loadAPIKey(for: profile.id),
                      ProviderConnectionRecord.identity(profile: current, key: currentKey) == identity else { continue }
                let record = ProviderCatalogRecord(identity: identity, fetchedAt: Date(), models: values)
                try await ProviderStateStore.shared.save(record, providerID: profile.id, category: "models")
                guard generations[profile.id] == token else { continue }
                records[profile.id] = record
                errors[profile.id] = nil
            } catch {
                guard generations[profile.id] == token else { continue }
                errors[profile.id] = "Model list unavailable. Retry refresh or keep using the configured model."
            }
        }
    }

    nonisolated static func fetch(profile: LLMProviderProfile, key: String) async throws -> [ProviderCatalogModel] {
        var url = try profile.modelsEndpoint()
        var rows: [[String: Any]] = []
        var cursors: Set<String> = []
        repeat {
            var request = URLRequest(url: url, timeoutInterval: 20)
            if profile.agentProtocol == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw LLMProviderConnectionError.transport("Model discovery failed.")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let page = root["data"] as? [[String: Any]] else {
                throw LLMProviderConnectionError.transport("Invalid model list.")
            }
            rows += page
            guard profile.agentProtocol == .anthropic, root["has_more"] as? Bool == true,
                  let cursor = root["last_id"] as? String, cursors.insert(cursor).inserted else { break }
            var components = URLComponents(url: try profile.modelsEndpoint(), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
            url = components.url!
        } while !Task.isCancelled
        try Task.checkCancellation()
        return select(rows: rows, router: profile.agentProtocol == .openAICompatible)
    }

    nonisolated static func select(rows: [[String: Any]], router: Bool) -> [ProviderCatalogModel] {
        // Version series, not release-date snapshots. Each Claude family has
        // its own three-series window; OpenAI shares a GPT series window.
        var groups: [String: [(String, String, ChatModelCapability)]] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !LLMModelLifecycle.isRetired(id) else { continue }
            if router && !id.hasPrefix("openai/") && !id.hasPrefix("anthropic/") { continue }
            let name = LLMReasoningEffort.leafModelName(id)
            guard !name.contains(":") else { continue }
            guard !["preview", "beta", "experimental", "latest", "chat", "audio", "realtime", "image", "search", "codex", "embedding", "instruct", "pro"].contains(where: { name.contains($0) }) else { continue }
            let pattern: String
            let family: String
            if name.hasPrefix("gpt-") {
                family = "gpt"
                pattern = "^gpt-([0-9]+(?:\\.[0-9]+)?)(?:-|$)"
            } else if let match = ["haiku", "sonnet", "opus"].first(where: { name.contains($0) }), name.hasPrefix("claude-") {
                family = match
                pattern = "^claude-(?:" + match + "-)?([0-9]+(?:\\.[0-9]+)?)(?:-([0-9]{1,2})(?:-|$))?"
            } else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let majorRange = Range(match.range(at: 1), in: name) else { continue }
            var series = String(name[majorRange])
            if match.numberOfRanges > 2, let minorRange = Range(match.range(at: 2), in: name) { series += "." + name[minorRange] }
            var capability = ChatModelCapability.known(name)
            if let capabilities = row["capabilities"] as? [String: Any] {
                let thinking = capabilities["thinking"] as? [String: Any]
                let types = thinking?["types"] as? [String: Any]
                let effort = capabilities["effort"] as? [String: Any]
                let supported = LLMReasoningEffort.allCases.filter { (effort?[$0.rawValue] as? [String: Any])?["supported"] as? Bool == true }
                if !supported.isEmpty, (types?["adaptive"] as? [String: Any])?["supported"] as? Bool == true {
                    capability = .init(thinking: .adaptive, efforts: supported)
                } else if (types?["enabled"] as? [String: Any])?["supported"] as? Bool == true {
                    capability = .init(thinking: .budget, efforts: [.none, .low, .medium, .high])
                } else { capability = .init(thinking: .automatic, efforts: []) }
            }
            capability.maxOutputTokens = row["max_tokens"] as? Int ?? capability.maxOutputTokens
            if router, let parameters = row["supported_parameters"] as? [String], !parameters.contains("reasoning") {
                capability = .init(thinking: .automatic, efforts: [])
            }
            if router, let reasoning = row["reasoning"] as? [String: Any] {
                let mandatory = reasoning["mandatory"] as? Bool == true
                if let advertised = reasoning["supported_efforts"] as? [String] {
                    let efforts = LLMReasoningEffort.allCases.filter { advertised.contains($0.rawValue) && (!mandatory || $0 != .none) }
                    capability = .init(thinking: efforts.isEmpty ? .automatic : .effort, efforts: efforts)
                } else if reasoning["supported_efforts"] is NSNull {
                    capability = .init(thinking: .effort, efforts: LLMReasoningEffort.allCases.filter { !mandatory || $0 != .none })
                } else if reasoning["supports_max_tokens"] as? Bool == true {
                    capability = .init(thinking: .budget, efforts: (mandatory ? [] : [.none]) + [.low, .medium, .high])
                } else { capability = .init(thinking: .automatic, efforts: []) }
            }
            groups[family, default: []].append((id, series, capability))
        }
        return groups.keys.sorted().flatMap { family -> [ProviderCatalogModel] in
            let values = groups[family]!
            let versions = Array(Set(values.map { $0.1 })).sorted { $0.compare($1, options: .numeric) == .orderedDescending }.prefix(3)
            var seen: Set<String> = []
            return values.sorted { $0.0.count == $1.0.count ? $0.0 > $1.0 : $0.0.count < $1.0.count }.compactMap { id, version, capability in
                guard versions.contains(version) else { return nil }
                let base = id.replacingOccurrences(of: "-(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$", with: "", options: .regularExpression)
                guard seen.insert(base).inserted else { return nil }
                return ProviderCatalogModel(id: id, capability: capability)
            }
        }
    }
}
