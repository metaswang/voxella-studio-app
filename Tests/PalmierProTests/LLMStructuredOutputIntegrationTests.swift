import Foundation
import Testing
@testable import PalmierPro

@Suite("Configured LLM structured output integration")
struct LLMStructuredOutputIntegrationTests {
    private static let enabled =
        ProcessInfo.processInfo.environment["VOXELLA_RUN_LLM_INTEGRATION"] == "1"

    @Test(.enabled(if: enabled))
    @MainActor
    func configuredProviderProducesChineseSubtitleJSON() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.voxella.studio"))
        let settings = LLMSettingsStore(defaults: defaults)
        let configuration = try await settings.runtimeConfiguration()
        let transcript = TranscriptionResult(
            text: "请测试一下声音。",
            language: "zh",
            words: [
                .init(text: "请", start: 0, end: 0.3, speaker: nil),
                .init(text: "测", start: 0.3, end: 0.6, speaker: nil),
                .init(text: "试", start: 0.6, end: 0.9, speaker: nil),
                .init(text: "一", start: 0.9, end: 1.1, speaker: nil),
                .init(text: "下", start: 1.1, end: 1.3, speaker: nil),
                .init(text: "声", start: 1.3, end: 1.7, speaker: nil),
                .init(text: "音。", start: 1.7, end: 2.1, speaker: nil),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(
            client: OpenAICompatibleClient(configuration: configuration)
        ).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(!track.cues.isEmpty)
        #expect(track.cues.flatMap(\.sourceIDs) == Array(0..<7))
        #expect(track.cues.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
