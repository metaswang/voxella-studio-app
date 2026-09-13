import Foundation
import Testing
@testable import PalmierPro

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import MLXAudioLID

@Suite("Session language vote experiment", .serialized)
struct LanguageVoteSessionExperiment {
    private static let manifest = ProcessInfo.processInfo.environment["VOXSTUDIO_LID_MANIFEST"]

    @Test(.enabled(if: manifest != nil))
    func identifyShortAudioWithoutDurationGate() async throws {
        try await Task.detached {
            let manifestURL = URL(fileURLWithPath: try #require(Self.manifest))
            let items = try JSONDecoder().decode([Input].self, from: Data(contentsOf: manifestURL))
            let input = try #require(items.first { $0.id == "short-en" })
            let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: input.path), targetSampleRate: 16_000)
            let duration = Double(samples.count) / 16_000
            #expect(duration > 0 && duration < 3)
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            let model = try EcapaTdnn.fromModelDirectory(LocalModelManager.directory(for: .spokenLanguageID))
            let evidence = try LocalSpeechPipeline.languageIdentificationEvidence(
                samples: samples, speechRanges: [.init(start: 0, end: duration)], languageIdentifier: model
            )
            #expect(!evidence.isEmpty)
            #expect(evidence.allSatisfy { !$0.posterior.isEmpty && $0.posterior.values.allSatisfy(\.isFinite) })
            let route = ASREngineRouter.decide(evidence: evidence)
            #expect(route.reason != .insufficientSpeech && route.reason != .invalidLanguageEvidence)
            #expect(route.whisperHint == nil)
            let output = ShortOutput(
                duration: duration, engine: route.engine.rawValue, reason: route.reason.rawValue,
                windows: evidence.map { .init(slices: $0.window.slices.map { [$0.start, $0.end] }, posterior: $0.posterior) }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(output).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("short-input-results.json"), options: .atomic)
            print("SHORT_LID duration=\(duration) windows=\(evidence.count) engine=\(route.engine.rawValue) reason=\(route.reason.rawValue)")
        }.value
    }

    @Test(.enabled(if: manifest != nil))
    func compareSessionRoutes() async throws {
        try await Task.detached {
            let manifestURL = URL(fileURLWithPath: try #require(Self.manifest))
            let items = try JSONDecoder().decode([Input].self, from: Data(contentsOf: manifestURL))
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            let model = try EcapaTdnn.fromModelDirectory(LocalModelManager.directory(for: .spokenLanguageID))
            var outputs: [Output] = []
            for item in items {
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let decoded = try AudioFileLoader.load(url: URL(fileURLWithPath: item.path), targetSampleRate: 16_000)
                let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decoded)
                let original = try await ASRSpeechProbabilityService.shared.probabilities(samples: decoded, progress: { _, _, _ in })
                let rescued = rescue.didApplyGain
                    ? try await ASRSpeechProbabilityService.shared.probabilities(samples: rescue.samples, progress: { _, _, _ in }) : nil
                let preparation = ASRSpeechPreparation.make(sampleCount: decoded.count, originalProbabilities: original, rescuedProbabilities: rescued)
                let evidence = try LocalSpeechPipeline.languageIdentificationEvidence(
                    samples: rescue.samples, speechRanges: preparation.confidentSpeechRanges, languageIdentifier: model
                )
                let route = ASREngineRouter.decide(evidence: evidence)
                let vote = try #require(route.languageVote)
                var average: [String: Float] = [:]
                for sample in evidence {
                    for (language, probability) in sample.posterior {
                        average[language, default: 0] += probability / Float(evidence.count)
                    }
                }
                let scores = Self.legacyScores(from: average)
                let oldEngine: ASREngine
                if scores.leading.score >= 0.80 && scores.margin >= 0.25 {
                    oldEngine = scores.leading.engine
                } else if scores.leading.engine == .whisper && scores.leading.score >= 0.50 {
                    oldEngine = .whisper
                } else if abs(scores.qwen - scores.parakeet) < 0.25 && max(scores.qwen, scores.parakeet) >= scores.whisper {
                    oldEngine = .qwen
                } else {
                    oldEngine = scores.leading.engine
                }
                let output = Output(
                    id: item.id, reference: item.reference, duration: Double(decoded.count) / 16_000,
                    windows: evidence.map { .init(slices: $0.window.slices.map { [$0.start, $0.end] }, posterior: $0.posterior) },
                    oldLanguage: ASREngineRouter.topLanguage(in: average)?.language, oldEngine: oldEngine.rawValue,
                    newLanguage: route.topLanguage, newEngine: route.engine.rawValue, reason: route.reason.rawValue,
                    pooled: vote.posterior, shares: vote.weightShares, anchors: vote.anchorLanguages,
                    whisperHint: route.whisperHint,
                    seconds: Double(start.duration(to: .now).components.attoseconds) / 1e18 + Double(start.duration(to: .now).components.seconds)
                )
                outputs.append(output)
                print("LID_EXPERIMENT id=\(item.id) reference=\(item.reference) old=\(oldEngine.rawValue)/\(output.oldLanguage ?? "nil") new=\(route.engine.rawValue)/\(route.topLanguage ?? "nil") reason=\(route.reason.rawValue) pool=\(vote.confidence)")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(outputs).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("results.json"), options: .atomic)
                #expect(route.routeConfidence.isFinite)
                if item.id == "mixed-en-zh" { #expect(route.engine == .qwen) }
                if item.id == "short-en" { #expect(!evidence.isEmpty) }
            }
        }.value
    }

    private static func legacyScores(from posterior: [String: Float]) -> ASREngineScores {
        let qwen: Set<String> = ["zh", "yue", "ja", "ko", "th", "vi", "id", "ms", "hi", "ar", "tr"]
        let qwenScore = posterior.filter { qwen.contains($0.key) }.values.reduce(0, +)
        let parakeetScore = posterior.filter { ASREngineLanguagePolicy.parakeetLanguages.contains($0.key) }.values.reduce(0, +)
        return .init(qwen: qwenScore, parakeet: parakeetScore, whisper: max(0, 1 - qwenScore - parakeetScore))
    }

    private struct Input: Decodable, Sendable {
        let id: String
        let path: String
        let reference: String
    }
    private struct ShortOutput: Encodable {
        let duration: Double
        let engine: String
        let reason: String
        let windows: [Window]
    }
    private struct Window: Codable, Sendable {
        let slices: [[Double]]
        let posterior: [String: Float]
    }
    private struct Output: Codable, Sendable {
        let id: String
        let reference: String
        let duration: Double
        let windows: [Window]
        let oldLanguage: String?
        let oldEngine: String
        let newLanguage: String?
        let newEngine: String
        let reason: String
        let pooled: [String: Float]
        let shares: [Double]
        let anchors: [String]
        let whisperHint: String?
        let seconds: Double
    }
}
#endif
