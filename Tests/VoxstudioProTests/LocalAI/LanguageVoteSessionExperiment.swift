import Foundation
import Testing
@testable import VoxstudioPro

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import MLXAudioLID

@Suite("Session language vote experiment", .serialized)
struct LanguageVoteSessionExperiment {
    private static let manifest = ProcessInfo.processInfo.environment["VOXSTUDIO_LID_MANIFEST"]
    private static let diagnoseAudio = ProcessInfo.processInfo.environment["VOXSTUDIO_LID_DIAGNOSE_AUDIO"]

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
            let sampled = try LocalSpeechPipeline.sampledLanguageIdentificationEvidence(
                samples: samples,
                languageIdentifier: model
            )
            let evidence = sampled.evidence
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
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let decoded = try AudioFileLoader.load(url: URL(fileURLWithPath: item.path), targetSampleRate: 16_000)
                let decodedAt = DispatchTime.now().uptimeNanoseconds
                let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decoded)
                let sampled = try LocalSpeechPipeline.sampledLanguageIdentificationEvidence(
                    samples: rescue.samples,
                    languageIdentifier: model
                )
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                let evidence = sampled.evidence
                #expect(sampled.sampling.isComplete)
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
                    samplingTarget: sampled.sampling.targetCount,
                    samplingAttempts: sampled.sampling.attemptedCount,
                    samplingComplete: sampled.sampling.isComplete,
                    decodingSeconds: Double(decodedAt - startedAt) / 1_000_000_000,
                    lidSeconds: Double(finishedAt - decodedAt) / 1_000_000_000,
                    seconds: Double(finishedAt - startedAt) / 1_000_000_000
                )
                outputs.append(output)
                print("LID_EXPERIMENT id=\(item.id) reference=\(item.reference) old=\(oldEngine.rawValue)/\(output.oldLanguage ?? "nil") new=\(route.engine.rawValue)/\(route.topLanguage ?? "nil") reason=\(route.reason.rawValue) pool=\(vote.confidence) accepted=\(evidence.count)/\(sampled.sampling.targetCount) attempted=\(sampled.sampling.attemptedCount) decode=\(output.decodingSeconds)s lid=\(output.lidSeconds)s")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(outputs).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("results.json"), options: .atomic)
                #expect(route.routeConfidence.isFinite)
                if item.id == "mixed-en-zh" { #expect(route.engine == .qwen) }
                if item.id == "short-en" { #expect(!evidence.isEmpty) }
            }
        }.value
    }

    @Test(.enabled(if: manifest != nil))
    func measureFullVADBaseline() async throws {
        try await Task.detached {
            let manifestURL = URL(fileURLWithPath: try #require(Self.manifest))
            let items = try JSONDecoder().decode([Input].self, from: Data(contentsOf: manifestURL))
            let item = try #require(items.first)
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let decoded = try AudioFileLoader.load(
                url: URL(fileURLWithPath: item.path),
                targetSampleRate: ASRAudioPreprocessor.sampleRate
            )
            let decodedAt = DispatchTime.now().uptimeNanoseconds
            let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decoded)
            let original = try await SpeechAnalysisService.shared.probabilities(
                samples: decoded,
                progress: { _, _, _ in }
            )
            let rescued = rescue.didApplyGain
                ? try await SpeechAnalysisService.shared.probabilities(
                    samples: rescue.samples,
                    progress: { _, _, _ in }
                )
                : nil
            let preparation = ASRSpeechPreparation.make(
                sampleCount: decoded.count,
                originalProbabilities: original,
                rescuedProbabilities: rescued
            )
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            print(
                "VAD_BASELINE id=\(item.id) decode=\(Double(decodedAt - startedAt) / 1_000_000_000)s "
                    + "vad=\(Double(finishedAt - decodedAt) / 1_000_000_000)s "
                    + "ranges=\(preparation.recognitionRanges.count) confident=\(preparation.confidentSpeechRanges.count) "
                    + "passes=\(rescue.didApplyGain ? 2 : 1)"
            )
        }.value
    }

    @Test(.enabled(if: diagnoseAudio != nil))
    func diagnoseProductionLIDWindows() async throws {
        try await Task.detached {
            let audioPath = try #require(Self.diagnoseAudio)
            let audioURL = URL(fileURLWithPath: audioPath)
            let decoded = try AudioFileLoader.load(
                url: audioURL,
                targetSampleRate: ASRAudioPreprocessor.sampleRate
            )
            let duration = Double(decoded.count) / Double(ASRAudioPreprocessor.sampleRate)
            let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decoded)
            let productionAnalysis = try await SpeechAnalysisService.shared.analyze(
                samples: decoded,
                threshold: SpeechAdmissionPolicy.standard.entryThreshold,
                progress: { _, _, _ in }
            )
            let productionAdmission = SpeechAdmission.decide(
                samples: decoded,
                originalProbabilities: productionAnalysis.probabilities,
                originalSegments: productionAnalysis.segments,
                modelRevision: productionAnalysis.modelRevision,
                intent: .standard
            )
            let referenceAnalysis = try await SpeechAnalysisService.shared.analyze(
                samples: decoded,
                threshold: VoiceReferenceSpeechGate.vadEntryThreshold,
                progress: { _, _, _ in }
            )
            let referenceIntervals = referenceAnalysis.segments.map {
                VoiceReferenceSpeechInterval(startTime: Double($0.startTime), endTime: Double($0.endTime))
            }
            let referenceSpan = VoiceReferenceSpeechGate.trimmedSpan(
                samples: decoded,
                sampleRate: Double(ASRAudioPreprocessor.sampleRate),
                speechIntervals: referenceIntervals
            )
            let energyKeptRanges = Self.energyKeptRanges(
                samples: decoded,
                speechRanges: productionAdmission.acceptedRanges
            )
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            let model = try EcapaTdnn.fromModelDirectory(LocalModelManager.directory(for: .spokenLanguageID))
            let conditions: [(String, [ASRSpeechRange])] = [
                ("production_vad", productionAdmission.acceptedRanges),
                ("silero_raw_0_60", productionAnalysis.segments.map {
                    ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
                }),
                ("voice_ref_0_85", referenceSpan.map {
                    [ASRSpeechRange(
                        start: Double($0.lowerBound) / Double(ASRAudioPreprocessor.sampleRate),
                        end: Double($0.upperBound) / Double(ASRAudioPreprocessor.sampleRate)
                    )]
                } ?? []),
                ("energy_inside_production_vad", energyKeptRanges),
                ("oracle_en_1_5s", [ASRSpeechRange(start: 1.0, end: 5.58)]),
                ("later_burst_9s", [ASRSpeechRange(start: 8.8, end: 10.8)]),
                ("later_burst_13s", [ASRSpeechRange(start: 12.8, end: 14.0)]),
                ("later_burst_36s", [ASRSpeechRange(start: 35.5, end: 38.5)]),
                ("noise_bed_20_28s", [ASRSpeechRange(start: 20.0, end: 28.0)]),
            ]
            var conditionOutputs: [ConditionOutput] = []
            for (name, ranges) in conditions {
                let valid = ranges.filter { $0.end > $0.start }
                let evidence = valid.isEmpty
                    ? []
                    : try LocalSpeechPipeline.languageIdentificationEvidence(
                        samples: rescue.samples,
                        speechRanges: valid,
                        languageIdentifier: model
                    )
                let route = evidence.isEmpty
                    ? ASREngineRouter.decide(evidence: [])
                    : ASREngineRouter.decide(evidence: evidence)
                let qwenPrompt = route.engine == .qwen
                    ? ASREngineLanguagePolicy.qwenPromptLanguage(from: route.topLanguage)
                    : nil
                conditionOutputs.append(ConditionOutput(
                    name: name,
                    speechSeconds: valid.reduce(0) { $0 + $1.duration },
                    rangeCount: valid.count,
                    ranges: valid.map { [$0.start, $0.end] },
                    windows: evidence.map {
                        WindowSummary(
                            start: $0.window.start,
                            duration: $0.window.duration,
                            slices: $0.window.slices.map { [$0.start, $0.end] },
                            top: ASREngineRouter.rankedLanguages($0.posterior, limit: 5)
                                .map { Ranked(language: $0.language, confidence: $0.confidence) }
                        )
                    },
                    engine: route.engine.rawValue,
                    reason: route.reason.rawValue,
                    topLanguage: route.topLanguage,
                    qwenPrompt: qwenPrompt,
                    anchors: route.languageVote?.anchorLanguages ?? [],
                    pooled: route.languageVote?.confidence,
                    margin: route.languageVote?.margin
                ))
                print(
                    "LID_DIAGNOSE condition=\(name) speech=\(String(format: "%.2f", valid.reduce(0) { $0 + $1.duration }))s "
                        + "ranges=\(valid.count) engine=\(route.engine.rawValue) reason=\(route.reason.rawValue) "
                        + "top=\(route.topLanguage ?? "nil") prompt=\(qwenPrompt ?? "nil") "
                        + "windows=\(evidence.count)"
                )
            }
            let originalConditions: [(String, [ASRSpeechRange])] = [
                ("production_vad_original", productionAdmission.acceptedRanges),
                ("oracle_en_original_1_5s", [ASRSpeechRange(start: 1.0, end: 5.58)]),
                ("oracle_en_original_1_3s", [ASRSpeechRange(start: 1.0, end: 3.0)]),
                ("oracle_en_original_4_5s", [ASRSpeechRange(start: 4.25, end: 5.50)]),
            ]
            for (name, ranges) in originalConditions {
                let valid = ranges.filter { $0.end > $0.start }
                let evidence = try LocalSpeechPipeline.languageIdentificationEvidence(
                    samples: decoded,
                    speechRanges: valid,
                    languageIdentifier: model
                )
                let route = ASREngineRouter.decide(evidence: evidence)
                let qwenPrompt = route.engine == .qwen
                    ? ASREngineLanguagePolicy.qwenPromptLanguage(from: route.topLanguage)
                    : nil
                conditionOutputs.append(ConditionOutput(
                    name: name,
                    speechSeconds: valid.reduce(0) { $0 + $1.duration },
                    rangeCount: valid.count,
                    ranges: valid.map { [$0.start, $0.end] },
                    windows: evidence.map {
                        WindowSummary(
                            start: $0.window.start,
                            duration: $0.window.duration,
                            slices: $0.window.slices.map { [$0.start, $0.end] },
                            top: ASREngineRouter.rankedLanguages($0.posterior, limit: 5)
                                .map { Ranked(language: $0.language, confidence: $0.confidence) }
                        )
                    },
                    engine: route.engine.rawValue,
                    reason: route.reason.rawValue,
                    topLanguage: route.topLanguage,
                    qwenPrompt: qwenPrompt,
                    anchors: route.languageVote?.anchorLanguages ?? [],
                    pooled: route.languageVote?.confidence,
                    margin: route.languageVote?.margin
                ))
                print(
                    "LID_DIAGNOSE condition=\(name) speech=\(String(format: "%.2f", valid.reduce(0) { $0 + $1.duration }))s "
                        + "engine=\(route.engine.rawValue) reason=\(route.reason.rawValue) "
                        + "top=\(route.topLanguage ?? "nil") prompt=\(qwenPrompt ?? "nil")"
                )
            }
            let sampled = try LocalSpeechPipeline.sampledLanguageIdentificationEvidence(
                samples: rescue.samples,
                languageIdentifier: model
            )
            let sampledRoute = ASREngineRouter.decide(evidence: sampled.evidence)
            conditionOutputs.append(ConditionOutput(
                name: "clip_sampler",
                speechSeconds: sampled.sampling.windows.reduce(0) { $0 + $1.duration },
                rangeCount: sampled.sampling.windows.count,
                ranges: sampled.sampling.windows.map { [$0.start, $0.start + $0.duration] },
                windows: sampled.evidence.map {
                    WindowSummary(
                        start: $0.window.start,
                        duration: $0.window.duration,
                        slices: $0.window.slices.map { [$0.start, $0.end] },
                        top: ASREngineRouter.rankedLanguages($0.posterior, limit: 5)
                            .map { Ranked(language: $0.language, confidence: $0.confidence) }
                    )
                },
                engine: sampledRoute.engine.rawValue,
                reason: sampledRoute.reason.rawValue,
                topLanguage: sampledRoute.topLanguage,
                qwenPrompt: sampledRoute.engine == .qwen
                    ? ASREngineLanguagePolicy.qwenPromptLanguage(from: sampledRoute.topLanguage)
                    : nil,
                anchors: sampledRoute.languageVote?.anchorLanguages ?? [],
                pooled: sampledRoute.languageVote?.confidence,
                margin: sampledRoute.languageVote?.margin
            ))
            print(
                "LID_DIAGNOSE condition=clip_sampler engine=\(sampledRoute.engine.rawValue) "
                    + "reason=\(sampledRoute.reason.rawValue) top=\(sampledRoute.topLanguage ?? "nil")"
            )
            let report = DiagnoseReport(
                audioPath: audioPath,
                duration: duration,
                originalRMSDBFS: rescue.original.rmsDBFS,
                processedRMSDBFS: rescue.processed.rmsDBFS,
                rescueGainDB: rescue.appliedGainDB,
                productionVAD: VADDump(
                    threshold: SpeechAdmissionPolicy.standard.entryThreshold,
                    rawSegments: productionAnalysis.segments.map { [$0.startTime, $0.endTime] },
                    admitted: productionAdmission.acceptedRanges.map { [$0.start, $0.end] },
                    acceptedSeconds: productionAdmission.diagnostics.acceptedSeconds,
                    rejectedSeconds: productionAdmission.diagnostics.rejectedSeconds,
                    p10: productionAdmission.diagnostics.originalProbabilityP10,
                    p50: productionAdmission.diagnostics.originalProbabilityP50,
                    p90: productionAdmission.diagnostics.originalProbabilityP90
                ),
                voiceReferenceVAD: VADDump(
                    threshold: VoiceReferenceSpeechGate.vadEntryThreshold,
                    rawSegments: referenceAnalysis.segments.map { [$0.startTime, $0.endTime] },
                    admitted: referenceSpan.map {
                        [[
                            Double($0.lowerBound) / Double(ASRAudioPreprocessor.sampleRate),
                            Double($0.upperBound) / Double(ASRAudioPreprocessor.sampleRate)
                        ]]
                    } ?? [],
                    acceptedSeconds: referenceSpan.map {
                        Double($0.count) / Double(ASRAudioPreprocessor.sampleRate)
                    } ?? 0,
                    rejectedSeconds: duration - (referenceSpan.map {
                        Double($0.count) / Double(ASRAudioPreprocessor.sampleRate)
                    } ?? 0),
                    p10: 0,
                    p50: 0,
                    p90: 0
                ),
                conditions: conditionOutputs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts/lid-vad-diagnose.json")
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(report).write(to: outputURL, options: .atomic)
            print("LID_DIAGNOSE wrote \(outputURL.path)")
            #expect(!productionAdmission.acceptedRanges.isEmpty)
        }.value
    }

    private static func energyKeptRanges(
        samples: [Float],
        speechRanges: [ASRSpeechRange]
    ) -> [ASRSpeechRange] {
        let rate = Double(ASRAudioPreprocessor.sampleRate)
        var kept: [ASRSpeechRange] = []
        for range in speechRanges {
            let start = min(samples.count, max(0, Int((range.start * rate).rounded(.down))))
            let end = min(samples.count, max(start, Int((range.end * rate).rounded(.up))))
            guard end > start else { continue }
            let slice = Array(samples[start..<end])
            guard let span = VoiceReferenceSpeechGate.trimmedSpan(
                samples: slice,
                sampleRate: rate,
                speechIntervals: [VoiceReferenceSpeechInterval(startTime: 0, endTime: Double(slice.count) / rate)]
            ) else { continue }
            kept.append(ASRSpeechRange(
                start: Double(start + span.lowerBound) / rate,
                end: Double(start + span.upperBound) / rate
            ))
        }
        return kept
    }

    private static func legacyScores(from posterior: [String: Float]) -> ASREngineScores {
        let qwen: Set<String> = ["zh", "yue", "ja", "ko", "th", "vi", "id", "ms", "hi", "ar", "tr"]
        let qwenScore = posterior.filter { qwen.contains($0.key) }.values.reduce(0, +)
        let parakeetScore = posterior.filter { ASREngineLanguagePolicy.parakeetLanguages.contains($0.key) }.values.reduce(0, +)
        return .init(qwen: qwenScore, parakeet: parakeetScore, whisper: max(0, 1 - qwenScore - parakeetScore))
    }

    private struct Ranked: Codable, Sendable {
        let language: String
        let confidence: Float
    }
    private struct WindowSummary: Codable, Sendable {
        let start: Double
        let duration: Double
        let slices: [[Double]]
        let top: [Ranked]
    }
    private struct ConditionOutput: Codable, Sendable {
        let name: String
        let speechSeconds: Double
        let rangeCount: Int
        let ranges: [[Double]]
        let windows: [WindowSummary]
        let engine: String
        let reason: String
        let topLanguage: String?
        let qwenPrompt: String?
        let anchors: [String]
        let pooled: Float?
        let margin: Float?
    }
    private struct VADDump: Codable, Sendable {
        let threshold: Float
        let rawSegments: [[Float]]
        let admitted: [[Double]]
        let acceptedSeconds: Double
        let rejectedSeconds: Double
        let p10: Float
        let p50: Float
        let p90: Float
    }
    private struct DiagnoseReport: Codable, Sendable {
        let audioPath: String
        let duration: Double
        let originalRMSDBFS: Double
        let processedRMSDBFS: Double
        let rescueGainDB: Double
        let productionVAD: VADDump
        let voiceReferenceVAD: VADDump
        let conditions: [ConditionOutput]
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
        let samplingTarget: Int
        let samplingAttempts: Int
        let samplingComplete: Bool
        let decodingSeconds: Double
        let lidSeconds: Double
        let seconds: Double
    }
}
#endif
