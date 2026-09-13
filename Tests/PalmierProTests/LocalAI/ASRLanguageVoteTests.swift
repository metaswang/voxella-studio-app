import Foundation
import Testing
@testable import PalmierPro

@Suite("Duration weighted engine evidence")
struct ASRLanguageVoteTests {
    @Test func overlappingCoverageDoesNotForceQwenForEuropeanLanguages() {
        let route = ASREngineRouter.decide(posterior: ["en": 0.41, "da": 0.44, "la": 0.15], speechDuration: 2)
        #expect(route.engine == .parakeet)
        #expect(route.scores.parakeet == route.scores.qwen)
    }

    @Test func sameEngineAsianEuropeanConflictUsesQwenCoverage() {
        let route = ASREngineRouter.decide(evidence: evidence([
            ["zh": 0.99, "th": 0.01], ["th": 0.8, "zh": 0.2], ["ro": 0.8, "zh": 0.2],
        ]))
        #expect(route.engine == .qwen)
        #expect(route.reason == .engineCoverage)
    }

    @Test func weakChineseTailDoesNotOverrideEuropeanCoverage() {
        let route = ASREngineRouter.decide(posterior: ["en": 0.60, "da": 0.25, "zh": 0.15], speechDuration: 5)
        #expect(route.engine == .parakeet)
    }

    @Test func parakeetDiagnosticLanguageStaysWithinItsCoverage() {
        let route = ASREngineRouter.decide(posterior: ["la": 0.40, "en": 0.31, "da": 0.29], speechDuration: 2)
        #expect(route.engine == .parakeet)
        #expect(route.topLanguage == "la")
        #expect(route.parakeetDomainLanguage == "en")
    }

    @Test func uncertainEvidenceAndUnsupportedLanguagesStillUseWhisper() {
        for posterior: [String: Float] in [["my": 0.71, "zh": 0.29], ["la": 0.89, "en": 0.11], ["en": 0.34, "my": 0.33, "la": 0.33]] {
            let route = ASREngineRouter.decide(posterior: posterior, speechDuration: 2)
            #expect(route.engine == .whisper)
            #expect(route.whisperHint == nil)
        }
    }

    @Test func unresolvedOtherLanguageCannotBeHiddenByChineseEnglishProtection() {
        let route = ASREngineRouter.decide(evidence: evidence([["zh": 1], ["en": 1], ["my": 1]]))
        #expect(route.engine == .whisper)
    }

    @Test func windowOutsideCoverageCannotBeHiddenByLongerCoveredAudio() {
        let rows = evidence(Array(repeating: ["en": Float(1)], count: 8) + [["my": 0.7, "en": 0.3]])
        #expect(ASREngineRouter.decide(evidence: rows).engine == .whisper)
    }

    @Test func modelCoverageIncludesEnglishButNotLatinOrBurmese() {
        #expect(ASREngineLanguagePolicy.qwenSupportedLanguages.count == 30)
        #expect(ASREngineLanguagePolicy.parakeetLanguages.count == 25)
        #expect(ASREngineLanguagePolicy.qwenSupportedLanguages.contains("en"))
        #expect(ASREngineLanguagePolicy.qwenSupportedLanguages.contains("ms"))
        #expect(!ASREngineLanguagePolicy.qwenSupportedLanguages.contains("my"))
        #expect(!ASREngineLanguagePolicy.parakeetLanguages.contains("la"))
        for code in ASREngineLanguagePolicy.qwenSupportedLanguages {
            #expect(ASREngineLanguagePolicy.isoCode(fromQwenLanguage: ASREngineLanguagePolicy.qwenPromptLanguage(from: code)) == code)
        }
    }

    @Test func emptyEvidenceStillFallsBack() {
        #expect(ASREngineRouter.decide(evidence: []).reason == .insufficientSpeech)
    }

    private func evidence(_ rows: [[String: Float]], seconds: Double = 5) -> [ASRLanguageEvidence] {
        rows.enumerated().map { index, posterior in
            .init(window: .init(slices: [.init(start: Double(index) * seconds, end: Double(index + 1) * seconds)]), posterior: posterior)
        }
    }

    @Test func confidentForeignWindowCannotDominateDurationWeights() throws {
        let samples = evidence([
            ["la": 0.88, "en": 0.12],
            ["en": 0.34, "la": 0.33, "fr": 0.33],
            ["en": 0.4, "la": 0.3, "fr": 0.3],
        ])
        let route = ASREngineRouter.decide(evidence: samples)
        let vote = try #require(route.languageVote)
        #expect(vote.weightShares.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000001 })
        #expect(vote.posterior["la", default: 0] < 0.51)
        #expect(route.engine == .whisper)
        #expect(route.reason == .insufficientEngineCoverage)
    }

    @Test(arguments: ["en", "zh", "sw", "fr", "ja"])
    func oneReliableWindowIsEnough(language: String) {
        let route = ASREngineRouter.decide(evidence: evidence([[language: 0.85, "is": 0.15]]))
        #expect(route.reason == (language == "sw" ? .insufficientEngineCoverage : .engineCoverage))
        #expect(route.engine == ASREngineLanguagePolicy.engine(forLanguageCode: language))
    }

    @Test(arguments: [0.1, 2.5, 2.999])
    func shortStrongSpeechUsesNormalRouting(seconds: Double) {
        let route = ASREngineRouter.decide(evidence: evidence([["en": 0.99, "ms": 0.01]], seconds: seconds))
        #expect(route.reason == .engineCoverage)
        #expect(route.engine == .parakeet)
        #expect(route.whisperHint == nil)
    }

    @Test func minorityStrongLanguageCannotBeHidden() {
        let samples = evidence(Array(repeating: ["en": Float(0.99), "zh": Float(0.01)], count: 8) + [["zh": 0.80, "en": 0.20]])
        let route = ASREngineRouter.decide(evidence: samples)
        #expect(route.reason == .chineseEnglishConflict)
        #expect(route.engine == .qwen)
        #expect(route.whisperHint == nil)
    }

    @Test func sameEngineLanguageSwitchUsesParakeet() {
        let route = ASREngineRouter.decide(evidence: evidence([["en": 0.9, "fr": 0.1], ["fr": 0.9, "en": 0.1]]))
        #expect(route.reason == .engineCoverage)
        #expect(route.engine == .parakeet)
    }

    @Test func strongOutlierCannotLockWhisperLanguage() {
        let samples = evidence([["la": 0.88, "en": 0.12], ["en": 0.34, "la": 0.33, "fr": 0.33], ["en": 0.4, "la": 0.3, "fr": 0.3]])
        let route = ASREngineRouter.decide(evidence: samples)
        #expect(route.engine == .whisper)
        #expect(route.reason == .insufficientEngineCoverage)
        #expect(route.routeConfidence < 0.51)
        #expect(route.whisperHint == nil)
    }

    @Test(arguments: [["en": Float(0.3), "zh": Float(0.3), "de": Float(0.4)], ["en": Float(0.5), "zh": Float(0.5)]])
    func weakEvidenceDoesNotNormalizeToCertainty(posterior: [String: Float]) {
        let vote = ASRLanguageVote.pool(evidence([posterior]))
        #expect(vote.reason == .noReliableLanguageAnchor)
        #expect(vote.confidence <= 0.5)
    }

    @Test func repeatedWindowsDoNotAddEvidence() {
        let samples = evidence([["en": 0.9, "zh": 0.1], ["en": 0.6, "zh": 0.4]])
        #expect(ASRLanguageVote.pool(samples) == ASRLanguageVote.pool(samples + samples))
    }

    @Test func orderDoesNotChangeDecision() {
        let samples = evidence([["en": 0.9, "zh": 0.1], ["en": 0.6, "zh": 0.4]])
        let a = ASRLanguageVote.pool(samples)
        let b = ASRLanguageVote.pool(samples.reversed())
        #expect(a.reason == b.reason)
        #expect(abs(a.confidence - b.confidence) < 0.000001)
    }

    @Test func durationWeightIsCapped() {
        let rows: [[String: Float]] = [["en": 0.9, "zh": 0.1], ["en": 0.6, "zh": 0.4]]
        #expect(ASRLanguageVote.pool(evidence(rows, seconds: 5)).confidence == ASRLanguageVote.pool(evidence(rows, seconds: 500)).confidence)
    }

    @Test func conflictingDuplicateOrOverlappingWindowsFailClosed() {
        let a = evidence([["en": 0.9, "zh": 0.1]])[0]
        let b = ASRLanguageEvidence(window: a.window, posterior: ["zh": 0.9, "en": 0.1])
        let c = ASRLanguageEvidence(window: .init(slices: [.init(start: 3, end: 8)]), posterior: a.posterior)
        #expect(ASRLanguageVote.pool([a, b]).reason == .invalidLanguageEvidence)
        #expect(ASRLanguageVote.pool([a, c]).reason == .invalidLanguageEvidence)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1])
    func invalidPolicyFailsClosed(value: Double) {
        let vote = ASRLanguageVote.pool(evidence([["en": 1]]), policy: .init(maximumSpeechDuration: value))
        #expect(vote.reason == .invalidLanguageEvidence)
    }

    @Test(arguments: [Float.nan, Float.infinity, -1])
    func invalidProbabilityFailsClosed(value: Float) {
        #expect(ASRLanguageVote.pool(evidence([["en": value, "zh": 0.1]])).reason == .invalidLanguageEvidence)
    }

    @Test func moderateOppositionCanRejectAnAnchor() {
        let samples = evidence([["en": 0.76, "zh": 0.24]] + Array(repeating: ["zh": Float(0.7), "en": Float(0.3)], count: 3))
        let vote = ASRLanguageVote.pool(samples)
        #expect(!vote.accepted)
    }

    @Test(arguments: [0.1, 2.0, 3.0, 6.0, 7.5, 9.0, 10.0, 12.5, 15.0, 60.0])
    func samplerNeverReusesSpeech(duration: Double) {
        let windows = ASREngineRouter.identificationWindows(
            speechRanges: [.init(start: 0, end: duration), .init(start: 0, end: duration)], audioDuration: duration
        )
        let slices = windows.flatMap(\.slices).sorted { $0.start < $1.start }
        #expect(zip(slices, slices.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
        #expect(windows.reduce(0) { $0 + $1.duration } <= duration + 1e-9)
    }
}
