import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Provider state and model catalog")
struct ProviderStateTests {
    @Test func connectionStatusSurvivesDatabaseReopenAndLatestResultWins() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("provider-state-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let first = ProviderConnectionRecord(providerID: id, identity: "endpoint|digest", testedAt: .now, error: nil, isRateLimited: false)
        let db = ProviderStateStore(url: url)
        let firstToken = UUID()
        try await db.beginConnection(providerID: id, token: firstToken)
        try await db.saveConnection(first, token: firstToken)
        let reopened = ProviderStateStore(url: url)
        #expect(try await reopened.load(ProviderConnectionRecord.self, providerID: id, category: "connection") == first)
        let lastToken = UUID()
        try await db.beginConnection(providerID: id, token: lastToken)
        let latest = ProviderConnectionRecord(providerID: id, identity: first.identity, testedAt: .now, error: "Rejected key", isRateLimited: false)
        try await db.saveConnection(latest, token: lastToken)
        try await db.saveConnection(first, token: firstToken)
        #expect(try await reopened.load(ProviderConnectionRecord.self, providerID: id, category: "connection") == latest)
        try await db.beginConnection(providerID: id, token: UUID(), invalidate: true)
        try await db.saveConnection(latest, token: lastToken)
        #expect(try await reopened.load(ProviderConnectionRecord.self, providerID: id, category: "connection") == nil)
    }

    @Test func statusIdentityDependsOnlyOnEndpointAndKey() {
        var profile = LLMProviderProfile(provider: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-6-sol")
        let identity = ProviderConnectionRecord.identity(profile: profile, key: "secret")
        #expect(!identity.contains("secret"))
        profile.displayName = "Renamed"
        profile.model = "gpt-6-luna"
        profile.baseURL += "/"
        #expect(ProviderConnectionRecord.identity(profile: profile, key: " secret ") == identity)
        #expect(ProviderConnectionRecord.identity(profile: profile, key: "new-key") != identity)
        profile.baseURL = "https://example.com/v1"
        #expect(ProviderConnectionRecord.identity(profile: profile, key: "secret") != identity)
    }

    @Test func catalogKeepsThreeFormalSeriesAndDeduplicatesSnapshots() {
        let ids = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-6-sol-20260901", "gpt-5.6-sol", "gpt-5.5", "gpt-5.5-2026-04-23", "gpt-5.4-mini", "gpt-7-preview", "gpt-6-realtime"]
        let models = ProviderModelCatalog.select(rows: ids.map { ["id": $0] }, router: false)
        #expect(Set(models.map(\.id)) == Set(["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.5"]))
        #expect(models.first(where: { $0.id == "gpt-6-astra" })?.capability.efforts.contains(.none) == false)
        #expect(models.first(where: { $0.id == "gpt-6-sol" })?.capability.efforts.contains(.max) == true)
    }

    @Test func routerOnlyOffersOpenAIAndClaudeAndKeepsThreeVersionsPerFamily() {
        let ids = ["openai/gpt-6-sol", "google/gemini-2.5-flash", "anthropic/claude-opus-5-5", "anthropic/claude-opus-5", "anthropic/claude-opus-4-8", "anthropic/claude-opus-4-7", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4-8", "anthropic/claude-sonnet-4-6", "anthropic/claude-haiku-4-5", "anthropic/claude-3-5-haiku-20241022", "anthropic/claude-fable-5"]
        let models = ProviderModelCatalog.select(rows: ids.map { ["id": $0, "supported_parameters": ["reasoning"]] }, router: true)
        #expect(models.filter { $0.id.contains("opus") }.count == 3)
        #expect(models.filter { $0.id.contains("sonnet") }.count == 3)
        #expect(models.filter { $0.id.contains("haiku") }.count == 2)
        #expect(!models.contains { $0.id.contains("gemini") || $0.id.contains("fable") || $0.id.contains("4-7") })
    }

    @Test func claudeCapabilitiesOverrideKnownDefaults() {
        let row: [String: Any] = ["id": "claude-sonnet-5", "capabilities": [
            "thinking": ["types": ["adaptive": ["supported": true]]],
            "effort": ["low": ["supported": true], "medium": ["supported": true]]]]
        let model = ProviderModelCatalog.select(rows: [row], router: false).first
        #expect(model?.capability.efforts == [.low, .medium])
        #expect(model?.capability.resolve(.max) == .medium)
    }

    @Test func realRouterDottedVersionsAndBatchVariantsAreNormalized() {
        let ids = ["anthropic/claude-opus-5.5", "anthropic/claude-opus-5", "anthropic/claude-opus-4.8", "anthropic/claude-opus-4.7", "anthropic/claude-opus-4.6", "anthropic/claude-opus-5.5:batch", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4.5", "anthropic/claude-sonnet-4", "openai/gpt-6-sol:batch", "openai/gpt-6-sol"]
        let models = ProviderModelCatalog.select(rows: ids.map { ["id": $0, "supported_parameters": ["reasoning"]] }, router: true)
        #expect(models.filter { $0.id.contains("opus") }.map(\.id).sorted() == ["anthropic/claude-opus-4.8", "anthropic/claude-opus-5", "anthropic/claude-opus-5.5"])
        #expect(models.filter { $0.id.contains("sonnet") }.count == 3)
        #expect(!models.contains { $0.id.contains(":") })
        #expect(ChatModelCapability.known("anthropic/claude-opus-4.6").efforts.contains(.xHigh) == false)
        #expect(ChatModelCapability.known("anthropic/claude-sonnet-4.5").thinking == .budget)
    }

    @Test func haikuUsesBudgetInsteadOfAdaptiveAndBudgetFitsOutputLimit() {
        let body = AnthropicRequestBody.build(modelName: "claude-haiku-4-5", reasoningEffort: .high, system: "Help", tools: [], messages: [])
        let thinking = body["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 8_192)
        #expect((body["max_tokens"] as? Int ?? 0) > 8_192)
        #expect(body["output_config"] == nil)
        let disabled = AnthropicRequestBody.build(modelName: "claude-haiku-4-5", reasoningEffort: .none, system: "Help", tools: [], messages: [])
        #expect(disabled["thinking"] as? [String: String] == ["type": "disabled"])
    }

    @Test func routerAdvertisedEffortsOverrideNativeModelDefaults() {
        let row: [String: Any] = ["id": "openai/gpt-6-sol", "supported_parameters": ["reasoning"],
            "reasoning": ["supported_efforts": ["none", "low", "high"], "mandatory": true]]
        let model = ProviderModelCatalog.select(rows: [row], router: true).first
        #expect(model?.capability.efforts == [.low, .high])
        #expect(model?.capability.resolve(.max) == .low)
    }

    @Test func signedOutWithoutBYOKCannotSelectCloudTransport() {
        #expect(AITransportPolicy.resolve(useBYOK: false, hasHostedAccess: false) == .unavailable)
        #expect(AITransportPolicy.resolve(useBYOK: true, hasHostedAccess: false) == .byok)
    }
}
