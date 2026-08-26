import Foundation
import Testing
@testable import PalmierPro

@Suite("ASR engine routing")
struct ASREngineRouterTests {
    @Test func languageSetsAreExclusiveAndCoverVoxLingua107() {
        let qwen = ASREngineLanguagePolicy.qwenLanguages
        let parakeet = ASREngineLanguagePolicy.parakeetLanguages
        let whisper = ASREngineLanguagePolicy.whisperLanguages
        let all = ASREngineLanguagePolicy.voxLingua107Languages

        #expect(all.count == 107)
        #expect(qwen.intersection(parakeet).isEmpty)
        #expect(qwen.subtracting(["yue"]).intersection(whisper).isEmpty)
        #expect(parakeet.intersection(whisper).isEmpty)
        #expect(qwen.subtracting(["yue"]).union(parakeet).union(whisper) == all)
        #expect(!all.contains("yue"))
        #expect(qwen.contains("zh"))
        #expect(qwen.contains("vi"))
        #expect(qwen.contains("yue"))
        #expect(whisper.contains("fa"))
        #expect(whisper.contains("mk"))
        #expect(whisper.contains("tl"))
        #expect(parakeet.contains("en"))
        #expect(parakeet.contains("fr"))
    }

    @Test func europeanConfusionStaysInParakeet() {
        let posterior: [String: Float] = [
            "en": 0.41,
            "de": 0.27,
            "nl": 0.13,
            "fr": 0.07,
            "sv": 0.04,
            "ja": 0.02,
        ]
        let scores = ASREngineRouter.scores(from: posterior)
        #expect(scores.parakeet > 0.90)
        #expect(ASREngineRouter.isConfident(scores))
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .parakeet)
        #expect(decision.reason == .confident)
        #expect(decision.parakeetDomainLanguage == "en")
    }

    @Test func eastAsianConfusionStaysInQwen() {
        let posterior: [String: Float] = [
            "ja": 0.43,
            "ko": 0.31,
            "zh": 0.14,
            "en": 0.05,
        ]
        let scores = ASREngineRouter.scores(from: posterior)
        #expect(scores.qwen > 0.85)
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .qwen)
        #expect(decision.reason == .confident)
    }

    @Test func cantoneseLeakageThroughChineseOrVietnameseStillSelectsQwen() {
        let posterior: [String: Float] = [
            "zh": 0.62,
            "vi": 0.21,
            "en": 0.05,
        ]
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .qwen)
        #expect(decision.reason == .confident)
    }

    @Test func qwenParakeetAmbiguityResolvesToQwen() {
        let posterior: [String: Float] = [
            "zh": 0.45,
            "en": 0.43,
            "sw": 0.12,
        ]
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .qwen)
        #expect(decision.reason == .qwenParakeetAmbiguous)
    }

    @Test func whisperDominantSelectsWhisper() {
        let posterior: [String: Float] = [
            "sw": 0.63,
            "zh": 0.19,
            "en": 0.18,
        ]
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .whisper)
        #expect(decision.reason == .whisperDominant)
        #expect(decision.whisperHint == nil)
    }

    @Test func highConfidenceWhisperLanguageBecomesHint() {
        var posterior: [String: Float] = [:]
        for language in ASREngineLanguagePolicy.voxLingua107Languages {
            posterior[language] = 0.001
        }
        posterior["sw"] = 0.92
        let decision = ASREngineRouter.decide(posterior: posterior, speechDuration: 3)
        #expect(decision.engine == .whisper)
        #expect(decision.reason == .confident)
        #expect(decision.whisperHint == "sw")
    }

    @Test func userLockedLanguagesSelectEnginesAndPrompts() {
        #expect(ASREngineLanguagePolicy.engine(forLanguageCode: "yue-CN") == .qwen)
        #expect(ASREngineLanguagePolicy.qwenPromptLanguage(from: "yue-CN") == "Cantonese")
        #expect(ASREngineLanguagePolicy.engine(forLanguageCode: "zh-CN") == .qwen)
        #expect(ASREngineLanguagePolicy.qwenPromptLanguage(from: "zh-CN") == "Chinese")
        #expect(ASREngineLanguagePolicy.engine(forLanguageCode: "en") == .parakeet)
        #expect(ASREngineLanguagePolicy.engine(forLanguageCode: "ja") == .qwen)
        #expect(ASREngineLanguagePolicy.engine(forLanguageCode: "fa") == .whisper)
        #expect(ASREngineLanguagePolicy.whisperLanguageCode(from: "iw") == "he")

        let locked = ASREngineRouter.decide(
            posterior: [:],
            speechDuration: 0,
            userLanguageCode: "yue-TW"
        )
        #expect(locked.engine == .qwen)
        #expect(locked.reason == .userLocked)
    }

    @Test func qwenDetectedNamesMapToISOIncludingCantonese() {
        #expect(ASREngineLanguagePolicy.isoCode(fromQwenLanguage: "Cantonese") == "yue")
        #expect(ASREngineLanguagePolicy.isoCode(fromQwenLanguage: "Chinese") == "zh")
        #expect(ASREngineLanguagePolicy.isoCode(fromQwenLanguage: "Japanese") == "ja")
        #expect(ASREngineLanguagePolicy.qwenLockLanguage(fromDetected: "Cantonese") == "Cantonese")
    }
}
