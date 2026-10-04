import AVFoundation
import Foundation
import NaturalLanguage

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import MLXAudioLID
import MLXAudioSTT
import MLXAudioTTS
import Qwen3ASR
#endif

enum LocalSpeechStage: String, Codable, Sendable {
    case decoding
    case detectingSpeech
    case detectingLanguage
    case recognizing
    case aligning
    case diarizing
    case assigningSpeakers
    case finalizing

    var title: String {
        switch self {
        case .decoding: "Decoding"
        case .detectingSpeech: "Detecting speech"
        case .detectingLanguage: "Detecting language"
        case .recognizing: "Recognizing"
        case .aligning: "Aligning"
        case .diarizing: "Diarizing"
        case .assigningSpeakers: "Assigning speakers"
        case .finalizing: "Finalizing"
        }
    }
}

struct LocalSpeechProgress: Equatable, Sendable {
    let stage: LocalSpeechStage
    let fraction: Double
    let completed: Int?
    let total: Int?
    let message: String
    let partialText: String?

    init(
        stage: LocalSpeechStage,
        fraction: Double,
        completed: Int? = nil,
        total: Int? = nil,
        message: String,
        partialText: String? = nil
    ) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
        self.completed = completed
        self.total = total
        self.message = message
        self.partialText = partialText
    }
}

struct LocalTranscriptionOutput: Sendable {
    let result: TranscriptionResult
    let diarizationDiagnostics: DiarizationDiagnostics
    let alignmentDiagnostics: TranscriptionAlignmentDiagnostics
    let engine: ASREngine
    let routeConfidence: Float
    let route: ASREngineRouteDecision
}

#if !BUNDLED_SPEECH
final class WhisperProductionReplayCollector {}
#endif

actor LocalSpeechPipeline {
    static let shared = LocalSpeechPipeline()

    #if BUNDLED_SPEECH
    private var whisper: (id: LocalModelID, model: WhisperModel)?
    private var qwen: (id: LocalModelID, model: MLXAudioSTT.Qwen3ASRModel)?
    private var parakeet: (id: LocalModelID, model: ParakeetModel)?
    private var languageIdentifier: EcapaTdnn?
    private var aligner: Qwen3ForcedAligner?
    private var streamingDiarizer: MLXStreamingSortformerEngine?
    #endif

    #if BUNDLED_SPEECH
    private func speakerTimeline(
        requestedSpeakerCount: Int?, samples: [Float], speechRanges: [SpeechTimeRange],
        audioDuration: Double, progress: @escaping @Sendable (DiarizationProgress) -> Void
    ) async throws -> SpeakerActivityTimeline {
        let descriptor = LocalModelManager.catalog.first { $0.id == .sortformerDiarization }!
        let installed = await Task.detached(priority: .utility) {
            LocalModelManager.isInstalled(descriptor)
        }.value
        return try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: requestedSpeakerCount, isInstalled: installed,
            speechRanges: speechRanges, audioDuration: audioDuration
        ) {
            let diarizer = try self.streamingDiarizationModel()
            return try await diarizer.diarize(
                audio: samples, sampleRate: 16_000, speechRanges: speechRanges,
                policy: .standard(requestedSpeakerCount: requestedSpeakerCount), progress: progress
            )
        }
    }
    #endif

    func transcribe(
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?,
        clipRangeSeconds: ClosedRange<Double>? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TranscriptionResult {
        try await transcribeDetailed(
            sourceURL: sourceURL,
            languageCode: languageCode,
            speakerCount: speakerCount,
            clipRangeSeconds: clipRangeSeconds,
            progressUpdate: { update in progress(update.fraction, update.message) }
        ).result
    }

    func transcribe(
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?,
        clipRangeSeconds: ClosedRange<Double>? = nil,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> TranscriptionResult {
        try await transcribeDetailed(
            sourceURL: sourceURL,
            languageCode: languageCode,
            speakerCount: speakerCount,
            clipRangeSeconds: clipRangeSeconds,
            progressUpdate: progressUpdate
        ).result
    }

    func transcribeDetailed(
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?,
        clipRangeSeconds: ClosedRange<Double>? = nil,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> LocalTranscriptionOutput {
        let output = try await processSpeech(
            sourceURL: sourceURL, languageCode: languageCode, speakerCount: speakerCount,
            clipRangeSeconds: clipRangeSeconds, textOnly: false, progressUpdate: progressUpdate
        )
        guard case .timed(let result) = output else { throw LocalAIError.emptyTranscript }
        return result
    }

    #if BUNDLED_SPEECH
    /// Runs the production ASR path and returns a trace without committing a
    /// Workbench result. This is intentionally routed through processSpeech so
    /// the replay observes the same VAD, scene gate, chunking, model and
    /// generation parameters as a real retranscription.
    func transcribeWhisperProductionReplay(
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?,
        clipRangeSeconds: ClosedRange<Double>? = nil
    ) async throws -> WhisperProductionReplay {
        let collector = WhisperProductionReplayCollector()
        let output = try await processSpeech(
            sourceURL: sourceURL,
            languageCode: languageCode,
            speakerCount: speakerCount,
            clipRangeSeconds: clipRangeSeconds,
            textOnly: false,
            replayCollector: collector,
            progressUpdate: { _ in }
        )
        guard case .timed(let transcription) = output else {
            throw LocalAIError.emptyTranscript
        }
        collector.setFinalRawText(transcription.result.text)
        return try collector.makeReplay()
    }

    /// Decoder-only entry point used by the reproducible Whisper tuning experiment.
    /// By default it bypasses app routing/VAD decisions while keeping the app's
    /// audio decode and low-level gain rescue identical to normal transcription.
    func transcribeWhisperForTuning(
        sourceURL: URL,
        languageCode: String?,
        clipRangeSeconds: ClosedRange<Double>? = nil,
        profile: WhisperASRTuningProfile,
        appVADPreprocessing: Bool = false,
        managedLease: Bool = true
    ) async throws -> WhisperTuningDecodeStats {
        if managedLease {
            return try await LocalSpeechScheduler.shared.withLease(jobID: UUID(), lane: .asr) {
                try await self.transcribeWhisperForTuning(
                    sourceURL: sourceURL,
                    languageCode: languageCode,
                    clipRangeSeconds: clipRangeSeconds,
                    profile: profile,
                    appVADPreprocessing: appVADPreprocessing,
                    managedLease: false
                )
            }
        }
        let modelID = LocalModelID.whisperLargeV3Turbo8Bit
        try Self.requireModels([modelID])
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }

        let preparedURL = try await DecodedAudioCache.file(for: sourceURL, range: clipRangeSeconds)
        let decodedSamples = try AudioFileLoader.load(
            url: preparedURL,
            targetSampleRate: ASRAudioPreprocessor.sampleRate
        )
        guard !decodedSamples.isEmpty else { throw LocalAIError.noAudioSamples }
        let originalMetrics = ASRAudioPreprocessor.metrics(for: decodedSamples)
        guard !originalMetrics.isEffectivelySilent else { throw LocalAIError.audioTooQuiet }
        let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decodedSamples)
        let samples = rescue.samples
        let audioDuration = Double(samples.count) / Double(ASRAudioPreprocessor.sampleRate)
        guard audioDuration > 0 else { throw LocalAIError.noAudioSamples }

        var vadElapsedSeconds = 0.0
        var vadModelRevision: String?
        var vadCandidateRangeCount = 0
        var vadAcceptedRangeCount = 0
        var vadAcceptedDurationSeconds = 0.0
        var vadRanges: [ASRSpeechRange] = []
        if appVADPreprocessing {
            let vadStartedAt = DispatchTime.now().uptimeNanoseconds
            let analysis = try await SpeechAnalysisService.shared.analyze(
                samples: decodedSamples,
                threshold: SpeechAdmissionPolicy.standard.entryThreshold,
                progress: { _, _, _ in }
            )
            let admission = SpeechAdmission.decide(
                samples: decodedSamples,
                originalProbabilities: analysis.probabilities,
                originalSegments: analysis.segments,
                modelRevision: analysis.modelRevision,
                intent: .standard
            )
            guard admission.hasAcceptedSpeech else { throw LocalAIError.vadNoSpeech }
            vadRanges = admission.acceptedRanges
            vadModelRevision = analysis.modelRevision
            vadCandidateRangeCount = admission.diagnostics.originalCandidateCount
            vadAcceptedRangeCount = admission.diagnostics.acceptedCount
            vadAcceptedDurationSeconds = admission.diagnostics.acceptedSeconds
            vadElapsedSeconds = Double(
                DispatchTime.now().uptimeNanoseconds - vadStartedAt
            ) / 1_000_000_000
        }

        let normalizedLanguage: String?
        if let languageCode {
            let trimmed = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "auto" || trimmed == "und" {
                normalizedLanguage = nil
            } else {
                normalizedLanguage = String(trimmed.split(separator: "-").first ?? Substring(trimmed))
            }
        } else {
            normalizedLanguage = nil
        }

        let loaded = try await asrModel(id: modelID, engine: .whisper)
        guard let whisper = loaded.whisper else { throw LocalAIError.modelsUnavailable }
        MLXRandom.seed(profile.seed)
        let outputs: [STTOutput]
        if appVADPreprocessing {
            outputs = vadRanges.compactMap { range in
                let start = min(
                    samples.count,
                    max(0, Int((range.start * Double(ASRAudioPreprocessor.sampleRate)).rounded(.down)))
                )
                let end = min(
                    samples.count,
                    max(start, Int((range.end * Double(ASRAudioPreprocessor.sampleRate)).rounded(.up)))
                )
                guard end > start else { return nil }
                return whisper.generate(
                    audio: MLXArray(Array(samples[start..<end])),
                    generationParameters: profile.generationParameters(language: normalizedLanguage)
                )
            }
        } else {
            outputs = [whisper.generate(
                audio: MLXArray(samples),
                generationParameters: profile.generationParameters(language: normalizedLanguage)
            )]
        }
        guard !outputs.isEmpty else { throw LocalAIError.vadNoSpeech }
        let text = outputs
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsedSeconds = outputs.reduce(0) { $0 + $1.totalTime }
        return WhisperTuningDecodeStats(
            text: text,
            language: outputs.compactMap(\.language).first,
            segmentCount: outputs.reduce(0) { $0 + ($1.segments?.count ?? 0) },
            promptTokens: outputs.reduce(0) { $0 + $1.promptTokens },
            generationTokens: outputs.reduce(0) { $0 + $1.generationTokens },
            totalTokens: outputs.reduce(0) { $0 + $1.totalTokens },
            elapsedSeconds: elapsedSeconds,
            realTimeFactor: elapsedSeconds / max(audioDuration, 0.001),
            peakMemoryGB: outputs.map(\.peakMemoryUsage).max() ?? 0,
            vadEnabled: appVADPreprocessing,
            vadElapsedSeconds: vadElapsedSeconds,
            vadModelRevision: vadModelRevision,
            vadCandidateRangeCount: vadCandidateRangeCount,
            vadAcceptedRangeCount: vadAcceptedRangeCount,
            vadInputDurationSeconds: appVADPreprocessing
                ? Double(decodedSamples.count) / Double(ASRAudioPreprocessor.sampleRate)
                : 0,
            vadAcceptedDurationSeconds: vadAcceptedDurationSeconds
        )
    }
    #endif

    func recognizeInput(
        sourceURL: URL,
        purpose: SpeechInputPurpose = .referenceAudio,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> SpeechInputResult {
        switch purpose {
        case .referenceAudio:
            return try await recognizeReferenceInput(sourceURL: sourceURL, progressUpdate: progressUpdate)
        case .quickInput:
            return try await recognizeQuickInput(sourceURL: sourceURL, progressUpdate: progressUpdate)
        }
    }

    private func recognizeReferenceInput(
        sourceURL: URL,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> SpeechInputResult {
        let output = try await processSpeech(
            sourceURL: sourceURL, languageCode: nil, speakerCount: 1,
            clipRangeSeconds: 0...SpeechInputResult.maximumDuration,
            textOnly: true, progressUpdate: progressUpdate
        )
        guard case .text(let result) = output else { throw LocalAIError.emptyTranscript }
        return result
    }

    private func recognizeQuickInput(
        sourceURL: URL,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void,
        managedLease: Bool = true
    ) async throws -> SpeechInputResult {
        if managedLease {
            return try await LocalSpeechScheduler.shared.withLease(
                jobID: UUID(), lane: .asr,
                onQueued: {
                    progressUpdate(.init(
                        stage: .recognizing, fraction: 0,
                        message: "Waiting for on-device processing to finish…"
                    ))
                }
            ) {
                try await self.recognizeQuickInput(
                    sourceURL: sourceURL,
                    progressUpdate: progressUpdate,
                    managedLease: false
                )
            }
        }
        progressUpdate(.init(stage: .decoding, fraction: 0, message: "Preparing local recognition…"))
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw LocalAIError.noAudioSamples }

        let segments = SpeechInputSegmentPlanner.segments(forDuration: duration)
        var text = ""
        var languageCode: String?
        var engine: ASREngine?

        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let overallStart = Double(index) / Double(segments.count)
            let overallSpan = 1 / Double(segments.count)
            let currentLanguage = languageCode
            let prefix = text
            let result = try await SpeechInputRecovery.recognize(range: segment) { range in
                let output = try await self.processSpeech(
                    sourceURL: sourceURL,
                    languageCode: currentLanguage,
                    speakerCount: 1,
                    clipRangeSeconds: range,
                    textOnly: true,
                    progressUpdate: { update in
                        progressUpdate(.init(
                            stage: update.stage,
                            fraction: overallStart + update.fraction * overallSpan,
                            completed: index,
                            total: segments.count,
                            message: update.message,
                            partialText: update.partialText.map { SpeechInputTextMerger.append(prefix, $0) }
                        ))
                    }
                )
                guard case .text(let result) = output else { throw LocalAIError.emptyTranscript }
                return result
            }
            guard let result else { continue }
            text = SpeechInputTextMerger.append(text, result.text)
            languageCode = result.languageCode ?? languageCode
            engine = result.engine
        }

        guard let engine, !text.isEmpty else { throw LocalAIError.emptyTranscript }
        progressUpdate(.init(stage: .finalizing, fraction: 1, message: "Speech recognized locally."))
        return SpeechInputResult(text: text, languageCode: languageCode, engine: engine)
    }

    private enum SpeechOutput {
        case text(SpeechInputResult)
        case timed(LocalTranscriptionOutput)
    }

    private func processSpeech(
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?,
        clipRangeSeconds: ClosedRange<Double>?,
        textOnly: Bool,
        replayCollector: WhisperProductionReplayCollector? = nil,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void,
        managedLease: Bool = true
    ) async throws -> SpeechOutput {
        if managedLease {
            return try await LocalSpeechScheduler.shared.withLease(
                jobID: UUID(), lane: .asr,
                onQueued: {
                    progressUpdate(.init(
                        stage: .recognizing, fraction: 0,
                        message: "Waiting for on-device processing to finish…"
                    ))
                }
            ) {
                try await self.processSpeech(
                    sourceURL: sourceURL,
                    languageCode: languageCode,
                    speakerCount: speakerCount,
                    clipRangeSeconds: clipRangeSeconds,
                    textOnly: textOnly,
                    replayCollector: replayCollector,
                    progressUpdate: progressUpdate,
                    managedLease: false
                )
            }
        }
        #if BUNDLED_SPEECH
        let whisperFallbackModelID = LocalModelManager.preferredWhisperFallbackModelID()
        try Self.requireModels([.sileroVAD])
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }

        progressUpdate(.init(stage: .decoding, fraction: 0.03, message: "Decoding audio locally…"))
        let preparationStartedAt = DispatchTime.now().uptimeNanoseconds
        let decodedSamples: [Float]
        if textOnly {
            decodedSamples = try await SpeechInputAudio.samples(
                from: sourceURL,
                range: clipRangeSeconds,
                maximumDuration: clipRangeSeconds == nil ? SpeechInputResult.maximumDuration : nil
            )
        } else {
            let preparedURL = try await DecodedAudioCache.file(for: sourceURL, range: clipRangeSeconds)
            decodedSamples = try AudioFileLoader.load(url: preparedURL, targetSampleRate: ASRAudioPreprocessor.sampleRate)
        }
        guard !decodedSamples.isEmpty else { throw LocalAIError.noAudioSamples }
        let originalMetrics = ASRAudioPreprocessor.metrics(for: decodedSamples)
        guard !originalMetrics.isEffectivelySilent else {
            throw LocalAIError.audioTooQuiet
        }
        let rescue = ASRAudioPreprocessor.prepareVADRescue(samples: decodedSamples)
        if rescue.didApplyGain {
            progressUpdate(.init(
                stage: .decoding,
                fraction: 0.05,
                message: String(format: "Checking low-level speech (+%.1f dB)…", rescue.appliedGainDB)
            ))
        }
        let samples = rescue.samples
        let processedMetrics = rescue.processed
        let decodedDuration = Double(decodedSamples.count) / Double(ASRAudioPreprocessor.sampleRate)
        replayCollector?.setSource(
            path: sourceURL.path,
            clipStart: clipRangeSeconds?.lowerBound ?? 0,
            clipEnd: clipRangeSeconds?.upperBound ?? decodedDuration,
            decodedSamples: decodedSamples.count,
            preparedSamples: samples.count,
            decodedDuration: decodedDuration,
            original: originalMetrics,
            processed: processedMetrics,
            rescueGain: rescue.appliedGainDB
        )
        let preparationElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - preparationStartedAt
        ) / 1_000_000_000
        Log.transcription.notice(
            "Transcription audio preparation elapsed=\(String(format: "%.2f", preparationElapsed))s "
                + "decodedSamples=\(decodedSamples.count) preparedSamples=\(samples.count)"
        )
        let levelMessage = String(
            format: "ASR audio level originalRMS=%.1fdBFS originalPeak=%.1fdBFS processedRMS=%.1fdBFS processedPeak=%.1fdBFS gain=%.1fdB",
            originalMetrics.rmsDBFS,
            originalMetrics.peakDBFS,
            processedMetrics.rmsDBFS,
            processedMetrics.peakDBFS,
            rescue.appliedGainDB
        )
        Log.transcription.notice(levelMessage)

        let requestedLanguage = TranscriptionLanguage(code: languageCode)
        let vadTotalChunks = LocalSpeechVAD.chunkCount(for: decodedSamples.count)
        progressUpdate(.init(
            stage: .detectingSpeech,
            fraction: 0.10,
            completed: 0,
            total: vadTotalChunks,
            message: "Checking for speech locally…"
        ))

        let vadStartedAt = DispatchTime.now().uptimeNanoseconds
        let originalAnalysis = try await SpeechAnalysisService.shared.analyze(
            samples: decodedSamples,
            threshold: SpeechAdmissionPolicy.standard.entryThreshold,
            progress: { completed, total, message in
                let fraction = 0.10 + 0.03 * (Double(completed) / Double(max(1, vadTotalChunks)))
                progressUpdate(.init(
                    stage: .detectingSpeech,
                    fraction: fraction,
                    completed: completed,
                    total: vadTotalChunks,
                    message: message
                ))
            }
        )
        try Task.checkCancellation()
        let admission = SpeechAdmission.decide(
            samples: decodedSamples,
            originalProbabilities: originalAnalysis.probabilities,
            originalSegments: originalAnalysis.segments,
            modelRevision: originalAnalysis.modelRevision,
            intent: .standard
        )
        guard admission.hasAcceptedSpeech else {
            Log.transcription.warning(
                "ASR speech admission rejected policy=\(admission.diagnostics.policyVersion) "
                    + "frames=\(admission.diagnostics.originalFrameCount) "
                    + "candidates=\(admission.diagnostics.originalCandidateCount) "
                    + "p10=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP10)) "
                    + "p50=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP50)) "
                    + "p90=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP90))"
            )
            throw LocalAIError.vadNoSpeech
        }
        // ASR uses the VAD/SpeechAdmission ranges directly. Sound-scene
        // classification remains available to alignment, but it must not
        // remove admitted speech from the production transcription input.
        let allowedSpeechRanges = admission.acceptedRanges
        replayCollector?.setSpeechRanges(
            candidate: admission.acceptedRanges,
            accepted: allowedSpeechRanges,
            sceneVetoed: allowedSpeechRanges,
            finalAllowed: allowedSpeechRanges
        )
        guard !allowedSpeechRanges.isEmpty else { throw LocalAIError.vadNoSpeech }
        let speechRegions = allowedSpeechRanges.map {
            SpeechRegion(startTime: Float($0.start), endTime: Float($0.end))
        }
        let vadElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - vadStartedAt
        ) / 1_000_000_000
        Log.transcription.notice(
            "ASR speech admission policy=\(admission.diagnostics.policyVersion) "
                + "model=\(admission.diagnostics.modelRevision) "
                + "frames=\(admission.diagnostics.originalFrameCount) "
                + "candidates=\(admission.diagnostics.originalCandidateCount) "
                + "ranges=\(allowedSpeechRanges.count) acceptedSeconds=\(String(format: "%.2f", admission.diagnostics.acceptedSeconds)) "
                + "rejectedSeconds=\(String(format: "%.2f", admission.diagnostics.rejectedSeconds)) "
                + "p10=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP10)) "
                + "p50=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP50)) "
                + "p90=\(String(format: "%.3f", admission.diagnostics.originalProbabilityP90)) "
                + "rescueGain=\(String(format: "%.1f", rescue.appliedGainDB))dB "
                + "vadElapsed=\(String(format: "%.2f", vadElapsed))s"
        )

        let route: ASREngineRouteDecision
        var recognitionLanguageCode: String?
        var outputLanguageCode: String?
        if languageCode != nil {
            route = ASREngineRouter.decide(
                posterior: [:],
                speechDuration: 0,
                userLanguageCode: languageCode
            )
            recognitionLanguageCode = Self.promptLanguage(for: route.engine, code: languageCode)
            outputLanguageCode = requestedLanguage.outputLanguageCode
        } else {
            try Self.requireModels([.spokenLanguageID])
            progressUpdate(.init(
                stage: .detectingLanguage,
                fraction: 0.13,
                message: "Confirming language from detected speech…"
            ))
            route = try Self.routeAutomaticEngine(
                samples: samples,
                speechRanges: allowedSpeechRanges,
                languageIdentifier: try languageIdentifierModel()
            )
            recognitionLanguageCode = ASREngineLanguagePolicy.decoderLanguagePrompt(for: route)
            outputLanguageCode = nil
            progressUpdate(.init(
                stage: .detectingLanguage,
                fraction: 0.135,
                message: "Preparing speech recognition…"
            ))
        }
        replayCollector?.setRoute(route, languagePrompt: recognitionLanguageCode)

        let audioDuration = Double(samples.count) / 16_000
        let asrModelID = ASREngineLanguagePolicy.modelID(
            for: route.engine,
            whisperFallback: whisperFallbackModelID
        )
        try Self.requireModels([asrModelID])
        guard let asrDescriptor = LocalModelManager.catalog.first(where: { $0.id == asrModelID }) else {
            throw LocalAIError.modelsUnavailable
        }
        replayCollector?.setModel(id: asrModelID, descriptor: asrDescriptor)
        let baseChunkConfiguration: ASRChunkPlannerConfiguration
        if route.engine == .whisper, let specification = asrDescriptor.asrSpecification {
            baseChunkConfiguration = ASRChunkPlannerConfiguration(
                maximumWindowDuration: specification.maximumWindowDuration,
                boundaryContextDuration: specification.boundaryContextDuration,
                maximumMergeGap: specification.maximumMergeGap
            )
        } else {
            baseChunkConfiguration = route.engine.chunkConfiguration
        }
        let chunkConfiguration = ASRChunkPlannerConfiguration(
            maximumWindowDuration: baseChunkConfiguration.maximumWindowDuration,
            boundaryContextDuration: baseChunkConfiguration.boundaryContextDuration,
            maximumMergeGap: 0
        )
        let recognitionChunks = ASRChunkPlanner.chunks(
            speechRanges: allowedSpeechRanges,
            audioDuration: audioDuration,
            configuration: chunkConfiguration,
            allowedRanges: allowedSpeechRanges
        )
        guard !recognitionChunks.isEmpty else { throw LocalAIError.vadNoSpeech }
        replayCollector?.setChunks(recognitionChunks, configuration: chunkConfiguration)
        Log.transcription.notice(
            "ASR chunks engine=\(route.engine.rawValue) count=\(recognitionChunks.count) "
                + "window=\(String(format: "%.0f", chunkConfiguration.maximumWindowDuration))s "
                + "audio=\(String(format: "%.1f", audioDuration))s"
        )

        progressUpdate(.init(stage: .recognizing, fraction: 0.14, message: "Preparing speech recognition…"))
        let loadedASR = try await asrModel(id: asrModelID, engine: route.engine)
        var parameters = loadedASR.defaultParameters
        let usesWhisperP1ProductionTuning = route.engine == .whisper
        // P1 winner for local Whisper: deterministic decoding plus a mild
        // sign-aware repetition penalty. Keep Qwen/Parakeet defaults intact.
        parameters = STTGenerateParameters(
            maxTokens: textOnly ? min(parameters.maxTokens, SpeechInputResult.maximumTokens) : parameters.maxTokens,
            temperature: 0,
            topP: usesWhisperP1ProductionTuning ? 1.0 : parameters.topP,
            topK: usesWhisperP1ProductionTuning ? 0 : parameters.topK,
            verbose: false,
            language: recognitionLanguageCode,
            chunkDuration: route.engine == .parakeet ? 120 : parameters.chunkDuration,
            minChunkDuration: parameters.minChunkDuration,
            repetitionPenalty: usesWhisperP1ProductionTuning ? 1.10 : parameters.repetitionPenalty,
            repetitionContextSize: usesWhisperP1ProductionTuning ? 32 : parameters.repetitionContextSize
        )
        replayCollector?.setGenerationParameters(parameters)

        progressUpdate(.init(
            stage: .recognizing,
            fraction: 0.20,
            completed: 0,
            total: recognitionChunks.count,
            message: "Recognizing speech on this Mac…"
        ))
        var recognition = try recognize(
            samples: samples,
            chunks: recognitionChunks,
            model: loadedASR,
            parameters: &parameters,
            engine: route.engine,
            audioDuration: audioDuration,
            previewsText: textOnly,
            progressStart: 0.20,
            progressEnd: 0.50,
            replayCollector: replayCollector,
            progressUpdate: progressUpdate,
            chunkMessage: { "Recognizing speech chunk \($0) of \($1)…" }
        )
        replayCollector?.setFirstPassRawText(
            recognition.spans.map(\.text).joined(separator: " ")
        )
        let rawLexicalUnitCount = Self.lexicalUnitCount(recognition.spans)
        let qualityLanguageCode = ASREngineLanguagePolicy.normalizedISO(outputLanguageCode)
            ?? ASREngineLanguagePolicy.isoCode(fromQwenLanguage: recognition.language)
            ?? ASREngineLanguagePolicy.normalizedISO(recognitionLanguageCode)
        let quality = TranscriptionQualityProcessor.preprocess(
            spans: recognition.spans,
            languageCode: qualityLanguageCode
        )
        let ownership = ASROwnershipResolver.resolve(
            spans: quality.spans,
            languageCode: qualityLanguageCode, requireAudioEvidence: true
        )
        let recognizedSpans = ownership.spans
        let text = recognizedSpans.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { throw LocalAIError.asrNoSpeech }
        if route.engine == .qwen,
           let iso = ASREngineLanguagePolicy.isoCode(fromQwenLanguage: recognition.language) {
            outputLanguageCode = outputLanguageCode ?? TranscriptionLanguage(code: iso).outputLanguageCode
            if parameters.language == nil,
               let locked = ASREngineLanguagePolicy.qwenPromptLanguage(from: iso) {
                Log.transcription.notice(
                    "Qwen job language lock detected=\(recognition.language ?? "nil") iso=\(iso) prompt=\(locked)"
                )
                parameters = STTGenerateParameters(
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    verbose: parameters.verbose,
                    language: locked,
                    chunkDuration: parameters.chunkDuration,
                    minChunkDuration: parameters.minChunkDuration,
                    repetitionPenalty: parameters.repetitionPenalty,
                    repetitionContextSize: parameters.repetitionContextSize
                )
            }
        }
        let inferredLanguage = TranscriptionLanguage(
            code: ASREngineLanguagePolicy.isoCode(fromQwenLanguage: recognition.language)
                ?? recognition.language
                ?? Self.detectLanguageCode(in: text)
        )
        let resolvedLanguageCode = outputLanguageCode ?? inferredLanguage.outputLanguageCode
        if textOnly {
            try Task.checkCancellation()
            progressUpdate(.init(stage: .finalizing, fraction: 1, message: "Speech recognized locally."))
            return .text(SpeechInputResult(
                text: TranscriptSegmenter.joinedText(recognizedSpans.map(\.text)),
                languageCode: resolvedLanguageCode,
                engine: route.engine
            ))
        }
        progressUpdate(.init(
            stage: .aligning,
            fraction: 0.50,
            message: "Preparing alignment speech mask…"
        ))
        let speechMask = try await Self.makeAlignmentSpeechMask(
            samples: samples,
            speechRegions: speechRegions
        ) { update in
            progressUpdate(.init(
                stage: .aligning,
                fraction: 0.50 + update.fraction * 0.02,
                completed: update.completed,
                total: update.total,
                message: update.message
            ))
        }
        let alignmentLanguage = Self.alignerLanguage(from: resolvedLanguageCode)
        let nativeWords = Self.nativeWords(from: recognition.nativeTokens)
        let usesNativeTimestamps = route.engine == .parakeet && !nativeWords.isEmpty
        if route.engine == .parakeet {
            Log.transcription.notice(
                "Parakeet token postprocess tokens=\(recognition.nativeTokens.count) words=\(nativeWords.count)"
            )
        }
        let usesForcedAligner = !usesNativeTimestamps
            && ASREngineLanguagePolicy.supportsForcedAlignment(resolvedLanguageCode)
        let aligner = usesForcedAligner ? try await alignerModel() : nil
        let alignment = try timedWords(
            spans: recognizedSpans,
            nativeWords: nativeWords,
            usesNativeTimestamps: usesNativeTimestamps,
            language: alignmentLanguage,
            aligner: aligner,
            samples: samples,
            speechMask: speechMask,
            progressStart: 0.52,
            progressEnd: 0.70,
            progressUpdate: progressUpdate
        )
        var aligned = alignment.words
        var timingReferences = Self.timingReferences(alignment)
        let firstPassCovered = aligned.map {
            ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
        }

        let uncovered = ASRCoverageRepair.uncoveredSpeech(
            mask: speechMask,
            covered: firstPassCovered
        )
        var retriedUncoveredRangeCount = uncovered.count
        var retriedUncoveredSpeechSeconds = uncovered.reduce(0) { $0 + ($1.end - $1.start) }
        var retriedUncoveredAcceptedCount = 0
        var retriedUncoveredKeptFirstPassCount = 0
        var retryLexicalUnitCount = 0
        var atomicSegmentFallbackCount = recognition.timestampFallbackCount
        if !uncovered.isEmpty {
            let cores = uncovered
            let retryInputs = ASRCoverageRepair.retryRanges(
                from: cores,
                firstPassCovered: firstPassCovered,
                audioDuration: audioDuration
            )
            // Retry windows already carry the desired overlap. Do not let the
            // first-pass VAD region plus boundary context pull already-recognized
            // words back into an edge-hole decode.
            let retryChunkConfiguration = ASRChunkPlannerConfiguration(
                maximumWindowDuration: chunkConfiguration.maximumWindowDuration,
                boundaryContextDuration: 0,
                maximumMergeGap: 0
            )
            let retryChunks = ASRChunkPlanner.chunks(
                speechRanges: retryInputs,
                audioDuration: audioDuration,
                configuration: retryChunkConfiguration,
                allowedRanges: retryInputs
            )
            Log.transcription.notice(
                "coverage retry cores=\(retriedUncoveredRangeCount) seconds=\(String(format: "%.1f", retriedUncoveredSpeechSeconds)) "
                    + "inputs=\(retryInputs.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ",")) "
                    + "chunks=\(retryChunks.map { String(format: "%.2f-%.2f", $0.inputStart, $0.inputEnd) }.joined(separator: ","))"
            )
            if retryChunks.isEmpty {
                retriedUncoveredKeptFirstPassCount = cores.count
                Log.transcription.warning("coverage retry produced no recognition chunks")
            } else {
                progressUpdate(.init(
                    stage: .recognizing,
                    fraction: 0.70,
                    completed: 0,
                    total: retryChunks.count,
                    message: "Recognizing uncovered speech…"
                ))
                do {
                    let retryRecognition = try recognize(
                        samples: samples,
                        chunks: retryChunks,
                        model: loadedASR,
                        parameters: &parameters,
                        engine: route.engine,
                        audioDuration: audioDuration,
                        progressStart: 0.70,
                        progressEnd: 0.78,
                        replayCollector: replayCollector,
                        progressUpdate: progressUpdate,
                        chunkMessage: { "Recognizing uncovered speech \($0) of \($1)…" }
                    )
                    atomicSegmentFallbackCount += retryRecognition.timestampFallbackCount
                    retryLexicalUnitCount = Self.lexicalUnitCount(retryRecognition.spans)
                    if retryRecognition.spans.isEmpty {
                        retriedUncoveredKeptFirstPassCount = cores.count
                        Log.transcription.warning("coverage retry returned no spans; keeping first pass")
                    } else {
                        let retryQuality = TranscriptionQualityProcessor.preprocess(
                            spans: retryRecognition.spans,
                            languageCode: qualityLanguageCode ?? resolvedLanguageCode
                        )
                        let retryOwnership = ASROwnershipResolver.resolve(
                            spans: retryQuality.spans,
                            languageCode: qualityLanguageCode ?? resolvedLanguageCode,
                            requireAudioEvidence: true
                        )
                        if retryOwnership.spans.isEmpty {
                            retriedUncoveredKeptFirstPassCount = cores.count
                            Log.transcription.warning("coverage retry left no spans; keeping first pass")
                        } else {
                            let retryNativeWords = Self.nativeWords(from: retryRecognition.nativeTokens)
                            let retryAlignment = try timedWords(
                                spans: retryOwnership.spans,
                                nativeWords: retryNativeWords,
                                usesNativeTimestamps: usesNativeTimestamps && !retryNativeWords.isEmpty,
                                language: alignmentLanguage,
                                aligner: aligner,
                                samples: samples,
                                speechMask: speechMask,
                                progressStart: 0.78,
                                progressEnd: 0.88,
                                progressUpdate: progressUpdate
                            )
                            timingReferences.merge(Self.timingReferences(retryAlignment), uniquingKeysWith: { _, new in new })
                            retryLexicalUnitCount = retryAlignment.words.count
                            let firstPassCovered = aligned.map {
                                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
                            }
                            let retryCovered = retryAlignment.words.map {
                                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
                            }
                            let outcome = ASRCoverageRepair.retryOutcome(
                                firstPassCovered: firstPassCovered,
                                retryCovered: retryCovered,
                                cores: cores,
                                mask: speechMask
                            )
                            if outcome == .accept {
                                let kept = aligned.filter { word in
                                    !ASRCoverageRepair.overlaps(
                                        ASRSpeechRange(start: Double(word.startTime), end: Double(word.endTime)),
                                        with: cores
                                    )
                                }
                                let incoming = retryAlignment.words.filter { word in
                                    ASRCoverageRepair.overlaps(
                                        ASRSpeechRange(start: Double(word.startTime), end: Double(word.endTime)),
                                        with: cores
                                    )
                                }
                                aligned = (kept + incoming).sorted {
                                    if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                                    return $0.endTime < $1.endTime
                                }
                                retriedUncoveredAcceptedCount = cores.count
                            } else {
                                retriedUncoveredKeptFirstPassCount = cores.count
                                Log.transcription.notice(
                                    "coverage retry did not improve core coverage; keeping first pass "
                                        + "retryText=\(retryOwnership.spans.map(\.text).joined(separator: " "))"
                                )
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    retriedUncoveredKeptFirstPassCount = cores.count
                    Log.transcription.warning(
                        "coverage retry failed; keeping first pass: \(error.localizedDescription)"
                    )
                }
            }
        }

        Memory.clearCache()
        let speechRanges = speechRegions.map {
            SpeechTimeRange(start: Double($0.startTime), end: Double($0.endTime))
        }
        let diarizationPolicy = SpeakerDiarizationPolicy.standard(requestedSpeakerCount: speakerCount)
        let diarizeStart = retriedUncoveredRangeCount > 0 ? 0.88 : 0.72
        let diarizeSpan = retriedUncoveredRangeCount > 0 ? 0.10 : 0.18
        let timeline = try await speakerTimeline(
            requestedSpeakerCount: speakerCount, samples: samples,
            speechRanges: speechRanges, audioDuration: audioDuration
        ) { update in
            progressUpdate(.init(
                stage: .diarizing, fraction: diarizeStart + update.fraction * diarizeSpan,
                completed: update.completed, total: update.total, message: update.message
            ))
        }
        let assignStartedAt = DispatchTime.now().uptimeNanoseconds
        let attributed = timeline.diagnostics.backend == .unavailable || timeline.diagnostics.backend == .disabled
            ? LexicalSpeakerResolver.wordsWithoutSpeakerAttribution(to: aligned, audioDuration: audioDuration)
            : Self.assignSpeakers(
            to: aligned,
            timeline: timeline,
            audioDuration: audioDuration,
            languageCode: resolvedLanguageCode,
            policy: diarizationPolicy
        )
        let assignElapsed = Double(DispatchTime.now().uptimeNanoseconds - assignStartedAt) / 1_000_000_000
        Log.transcription.notice(
            "Speaker assignment elapsed=\(String(format: "%.2f", assignElapsed))s words=\(attributed.count)"
        )
        let attributedWithQuality = Self.applyingTimingQualities(attributed, references: timingReferences)
        let boundaryRefinement = try await refineSpeakerBoundaries(
            words: attributedWithQuality, timeline: timeline, samples: samples,
            languageCode: resolvedLanguageCode, policy: diarizationPolicy
        )
        let qualityStartedAt = DispatchTime.now().uptimeNanoseconds
        let words = TranscriptionQualityProcessor.postprocess(
            boundaryRefinement.words,
            chineseScript: TranscriptionLanguage(code: resolvedLanguageCode).chineseScript
        )
        let qualityElapsed = Double(DispatchTime.now().uptimeNanoseconds - qualityStartedAt) / 1_000_000_000
        Log.transcription.notice(
            "Transcript quality postprocess elapsed=\(String(format: "%.2f", qualityElapsed))s words=\(words.count)"
        )
        let segments = Self.makeSegments(from: words)
        progressUpdate(.init(stage: .finalizing, fraction: 0.99, message: "Finalizing transcript…"))
        let alignmentDiagnostics = TranscriptionAlignmentDiagnostics(
            trimmedHallucinatedSpanCount: quality.statistics.trimmedRepeatedSpans,
            rejectedAlignmentChunkCount: alignment.rejectedAlignmentChunkCount,
            retriedAlignmentChunkCount: alignment.retriedAlignmentChunkCount,
            estimatedUnitCount: alignment.coarseTimedUnitCount,
            longestRejectedUnitDuration: alignment.longestRejectedUnitDuration,
            removedDuplicatePrefixes: ownership.removedDuplicatePrefixes,
            removedDuplicateSuffixes: ownership.removedDuplicateSuffixes,
            removedContainedSpans: ownership.removedContainedSpans,
            atomicSegmentFallbackCount: atomicSegmentFallbackCount,
            reconciledBoundaryCount: ownership.reconciledBoundaryCount,
            unresolvedBoundaryCount: ownership.unresolvedBoundaryCount,
            retriedUncoveredRangeCount: retriedUncoveredRangeCount,
            retriedUncoveredSpeechSeconds: retriedUncoveredSpeechSeconds,
            retriedUncoveredAcceptedCount: retriedUncoveredAcceptedCount,
            retriedUncoveredKeptFirstPassCount: retriedUncoveredKeptFirstPassCount,
            rawLexicalUnitCount: rawLexicalUnitCount,
            qualityLexicalUnitCount: Self.lexicalUnitCount(quality.spans),
            ownershipLexicalUnitCount: Self.lexicalUnitCount(ownership.spans),
            alignmentLexicalUnitCount: aligned.count,
            retryLexicalUnitCount: retryLexicalUnitCount,
            finalLexicalUnitCount: words.count,
            speakerBoundaryRefinement: boundaryRefinement.diagnostics
        )
        try Task.checkCancellation()
        return .timed(LocalTranscriptionOutput(
            result: TranscriptionResult(
                text: TranscriptSegmenter.joinedText(words.map(\.text)),
                language: resolvedLanguageCode,
                words: words,
                segments: segments,
                asrEngine: route.engine
            ),
            diarizationDiagnostics: timeline.diagnostics,
            alignmentDiagnostics: alignmentDiagnostics,
            engine: route.engine,
            routeConfidence: route.routeConfidence,
            route: route
        ))
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    #if BUNDLED_SPEECH
    private func refineSpeakerBoundaries(
        words: [TranscriptionWord], timeline: SpeakerActivityTimeline, samples: [Float],
        languageCode: String?, policy: SpeakerDiarizationPolicy
    ) async throws -> SpeakerBoundaryRefiner.Result {
        let candidates = SpeakerBoundaryRefiner.candidates(words: words, timeline: timeline, languageCode: languageCode)
        guard !candidates.isEmpty else {
            return .init(words: words, diagnostics: .init())
        }
        guard ASREngineLanguagePolicy.supportsForcedAlignment(languageCode) else {
            return .init(words: words, diagnostics: .init(candidateCount: candidates.count, unresolvedCount: candidates.count))
        }
        // Keep CPU timeline probabilities; release the diarizer's model before
        // loading another model on the native-timestamp route. The caller holds
        // the pipeline inference gate throughout this operation.
        streamingDiarizer = nil
        Memory.clearCache()
        let language = Self.alignerLanguage(from: languageCode)
        return try await SpeakerBoundaryRefiner.refine(
            words: words, timeline: timeline, languageCode: languageCode, policy: policy
        ) { window in
            let model = try await self.alignerModel()
            let lower = max(0, Int((window.start * 16_000).rounded(.down)))
            let upper = min(samples.count, Int((window.end * 16_000).rounded(.up)))
            guard upper > lower else { throw LongFormAlignmentError.invalidSpan }
            let offset = Double(lower) / 16_000
            let local = model.align(audio: Array(samples[lower..<upper]), text: window.text,
                                    sampleRate: 16_000, language: language)
            return local.map {
                .init(text: $0.text, start: Double($0.startTime) + offset, end: Double($0.endTime) + offset)
            }
        }
    }
    #endif

    func alignScript(
        sourceURL: URL,
        text: String,
        languageCode: String?,
        speakerCount: Int?,
        anchor: TranscriptionResult? = nil
    ) async throws -> TranscriptionResult {
        try await alignKnownText(
            sourceURL: sourceURL,
            request: KnownTextAlignmentRequest(
                text: text,
                languageCode: languageCode,
                anchor: anchor,
                speakerAttribution: .diarize(requestedSpeakerCount: speakerCount)
            ),
            progressUpdate: { _ in }
        ).result
    }

    func alignKnownText(
        sourceURL: URL,
        request: KnownTextAlignmentRequest,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void,
        managedLease: Bool = true
    ) async throws -> KnownTextAlignmentOutput {
        if managedLease {
            return try await LocalSpeechScheduler.shared.withLease(jobID: UUID(), lane: .asr) {
                try await self.alignKnownText(
                    sourceURL: sourceURL,
                    request: request,
                    progressUpdate: progressUpdate,
                    managedLease: false
                )
            }
        }
        #if BUNDLED_SPEECH
        let script = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { throw LocalAIError.emptyTranscript }
        let requiredModels: [LocalModelID] = [.forcedAligner, .sileroVAD]
        try Self.requireModels(requiredModels)
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }

        progressUpdate(.init(stage: .decoding, fraction: 0.04, message: "Decoding audio for script alignment…"))
        let preparedURL = try await DecodedAudioCache.file(for: sourceURL)
        let decodedSamples = try AudioFileLoader.load(url: preparedURL, targetSampleRate: ASRAudioPreprocessor.sampleRate)
        let preprocessing = ASRAudioPreprocessor.prepare(samples: decodedSamples)
        guard !decodedSamples.isEmpty else { throw LocalAIError.noAudioSamples }
        guard !preprocessing.original.isEffectivelySilent else {
            throw LocalAIError.audioTooQuiet
        }
        let samples = preprocessing.samples
        let aligner = try await alignerModel()
        let requestedLanguage = request.languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLanguageCode = requestedLanguage == nil
            || requestedLanguage?.isEmpty == true
            || requestedLanguage?.lowercased() == "auto"
            ? (Self.detectLanguageCode(in: script) ?? "en")
            : requestedLanguage
        let language = Self.alignerLanguage(from: resolvedLanguageCode)
        let audioDuration = Double(samples.count) / 16_000
        let vadAnalysis = try await SpeechAnalysisService.shared.analyze(
            samples: decodedSamples,
            threshold: SpeechAdmissionPolicy.standard.entryThreshold,
            progress: { _, _, _ in }
        )
        let admission = SpeechAdmission.decide(
            samples: decodedSamples,
            originalProbabilities: vadAnalysis.probabilities,
            originalSegments: vadAnalysis.segments,
            modelRevision: vadAnalysis.modelRevision,
            intent: .standard
        )
        guard admission.hasAcceptedSpeech else {
            Log.transcription.warning(
                "alignment speech admission rejected policy=\(admission.diagnostics.policyVersion) "
                    + "frames=\(admission.diagnostics.originalFrameCount) "
                    + "candidates=\(admission.diagnostics.originalCandidateCount)"
            )
            throw LocalAIError.vadNoSpeech
        }
        let speechRegions = admission.acceptedRanges.map {
            SpeechRegion(startTime: Float($0.start), endTime: Float($0.end))
        }
        progressUpdate(.init(
            stage: .aligning,
            fraction: 0.10,
            message: "Preparing alignment speech mask…"
        ))
        let speechMask = try await Self.makeAlignmentSpeechMask(
            samples: samples,
            speechRegions: speechRegions
        ) { update in
            progressUpdate(.init(
                stage: .aligning,
                fraction: 0.10 + update.fraction * 0.02,
                completed: update.completed,
                total: update.total,
                message: update.message
            ))
        }
        let spans: [RecognizedSpan]
        if !request.spans.isEmpty {
            spans = try request.spans.map { span in
                let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty,
                      span.start.isFinite, span.end.isFinite,
                      span.start >= 0, span.start < audioDuration,
                      span.end > span.start else {
                    throw LongFormAlignmentError.invalidSpan
                }
                return RecognizedSpan(
                    text: text,
                    startTime: span.start,
                    endTime: min(audioDuration, span.end)
                )
            }
        } else if let anchor = request.anchor {
            spans = try LongFormAlignmentEngine.spansForEditedTranscript(
                text: script,
                original: anchor,
                audioDuration: audioDuration,
                language: language,
                aligner: aligner
            )
        } else if audioDuration <= AlignmentModelCapabilities.qwen3ForcedAligner.maximumChunkDuration {
            spans = [RecognizedSpan(text: script, startTime: 0, endTime: audioDuration)]
        } else {
            throw LongFormAlignmentError.insufficientAnchorCoverage(actual: 0, required: 0.65)
        }
        let aligned = try LongFormAlignmentEngine.alignDetailed(
            audio: samples,
            sampleRate: 16_000,
            spans: spans,
            language: language,
            aligner: aligner,
            speechMask: speechMask,
            progress: { fraction, message in
                progressUpdate(.init(
                    stage: .aligning,
                    fraction: 0.12 + fraction * 0.68,
                    message: message
                ))
            }
        )
        progressUpdate(.init(stage: .assigningSpeakers, fraction: 0.84, message: "Assigning script speakers…"))
        let untitledWords = LexicalSpeakerResolver.wordsWithoutSpeakerAttribution(
            to: aligned.words,
            audioDuration: audioDuration
        )
        let words: [TranscriptionWord]
        var speakerWarnings: [String] = []
        var boundaryDiagnostics: SpeakerBoundaryRefinementDiagnostics? = nil
        switch request.speakerAttribution {
        case .providedSpans:
            words = KnownTextSpeakerMapper.assign(words: untitledWords, spans: request.spans)
        case .none:
            words = untitledWords
        case .diarize(let requestedSpeakerCount):
            Memory.clearCache()
            let timeline = try await speakerTimeline(
                requestedSpeakerCount: requestedSpeakerCount, samples: samples,
                speechRanges: speechRegions.map {
                    SpeechTimeRange(start: Double($0.startTime), end: Double($0.endTime))
                }, audioDuration: audioDuration
            ) { update in
                progressUpdate(.init(
                    stage: .diarizing, fraction: 0.84 + update.fraction * 0.12,
                    completed: update.completed, total: update.total, message: update.message
                ))
            }
            speakerWarnings = timeline.diagnostics.warnings
            let attributed = timeline.diagnostics.backend == .unavailable || timeline.diagnostics.backend == .disabled ? untitledWords : Self.assignSpeakers(
                to: aligned.words, timeline: timeline, audioDuration: audioDuration,
                languageCode: resolvedLanguageCode,
                policy: .standard(requestedSpeakerCount: requestedSpeakerCount)
            )
            let refined = try await refineSpeakerBoundaries(
                words: Self.applyingTimingQualities(attributed, references: Self.timingReferences(aligned)),
                timeline: timeline, samples: samples, languageCode: resolvedLanguageCode,
                policy: .standard(requestedSpeakerCount: requestedSpeakerCount)
            )
            words = refined.words
            boundaryDiagnostics = refined.diagnostics
        }
        try Task.checkCancellation()
        progressUpdate(.init(stage: .finalizing, fraction: 0.98, message: "Building timed script segments…"))
        let result = TranscriptionResult(
            text: script,
            language: resolvedLanguageCode,
            words: boundaryDiagnostics == nil ? Self.applyingTimingQualities(words, references: Self.timingReferences(aligned)) : words,
            segments: Self.makeSegments(from: words)
        )
        progressUpdate(.init(stage: .finalizing, fraction: 1, message: "Script alignment ready"))
        return KnownTextAlignmentOutput(
            result: result,
            diagnostics: KnownTextAlignmentDiagnostics(
                alignedUnitCount: aligned.words.count,
                estimatedUnitCount: aligned.coarseTimedUnitCount,
                speakerWarnings: speakerWarnings, speakerBoundaryRefinement: boundaryDiagnostics
            )
        )
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    func releaseSessionModels() async {
        #if BUNDLED_SPEECH
        let hadSessionModel = aligner != nil || streamingDiarizer != nil
        guard hadSessionModel else { return }
        do {
            try await MLXRuntime.beginInference()
        } catch {
            aligner = nil
            streamingDiarizer = nil
            return
        }
        defer { MLXRuntime.endInference() }
        aligner = nil
        streamingDiarizer = nil
        MLXRuntime.releaseActivations()
        #endif
    }

    func releaseLane() async {
        #if BUNDLED_SPEECH
        let hadLargeModel = whisper != nil || qwen != nil || parakeet != nil
            || aligner != nil || streamingDiarizer != nil
        guard hadLargeModel else { return }
        do {
            try await MLXRuntime.beginInference()
        } catch {
            whisper = nil
            qwen = nil
            parakeet = nil
            aligner = nil
            streamingDiarizer = nil
            return
        }
        defer { MLXRuntime.endInference() }
        whisper = nil
        qwen = nil
        parakeet = nil
        aligner = nil
        streamingDiarizer = nil
        MLXRuntime.releaseActivations()
        #endif
    }

    #if BUNDLED_SPEECH
    private struct LoadedASR {
        var engine: ASREngine
        var id: LocalModelID
        var whisper: WhisperModel?
        var qwen: MLXAudioSTT.Qwen3ASRModel?
        var parakeet: ParakeetModel?

        var defaultParameters: STTGenerateParameters {
            switch engine {
            case .whisper: whisper?.defaultGenerationParameters ?? STTGenerateParameters()
            case .qwen: qwen?.defaultGenerationParameters ?? STTGenerateParameters()
            case .parakeet: parakeet?.defaultGenerationParameters ?? STTGenerateParameters()
            }
        }
    }

    private func asrModel(id: LocalModelID, engine: ASREngine) async throws -> LoadedASR {
        switch engine {
        case .whisper:
            if let whisper, whisper.id == id {
                return LoadedASR(engine: engine, id: id, whisper: whisper.model)
            }
            unloadASR()
            let loaded = try await WhisperModel.fromDirectory(LocalModelManager.directory(for: id))
            whisper = (id, loaded)
            return LoadedASR(engine: engine, id: id, whisper: loaded)
        case .qwen:
            if let qwen, qwen.id == id {
                return LoadedASR(engine: engine, id: id, qwen: qwen.model)
            }
            unloadASR()
            let loaded = try await MLXAudioSTT.Qwen3ASRModel.fromModelDirectory(LocalModelManager.directory(for: id))
            qwen = (id, loaded)
            return LoadedASR(engine: engine, id: id, qwen: loaded)
        case .parakeet:
            if let parakeet, parakeet.id == id {
                return LoadedASR(engine: engine, id: id, parakeet: parakeet.model)
            }
            unloadASR()
            let loaded = try ParakeetModel.fromDirectory(LocalModelManager.directory(for: id))
            parakeet = (id, loaded)
            return LoadedASR(engine: engine, id: id, parakeet: loaded)
        }
    }

    private func unloadASR() {
        let hadLoadedModel = whisper != nil || qwen != nil || parakeet != nil
        whisper = nil
        qwen = nil
        parakeet = nil
        // Clearing MLX memory before the first model load can initialize the
        // Metal allocator in a headless CLI process and crash when no device
        // list has been created yet. There is nothing to reclaim in that case.
        if hadLoadedModel {
            MLXRuntime.releaseActivations()
        }
    }

    private func alignerModel() async throws -> Qwen3ForcedAligner {
        if let aligner { return aligner }
        let descriptor = LocalModelManager.catalog.first { $0.id == .forcedAligner }!
        let loaded = try await Qwen3ForcedAligner.fromPretrained(
            modelId: descriptor.repository,
            cacheDir: LocalModelManager.directory(for: .forcedAligner),
            offlineMode: true
        )
        aligner = loaded
        return loaded
    }

    private func languageIdentifierModel() throws -> EcapaTdnn {
        if let languageIdentifier { return languageIdentifier }
        let loaded = try EcapaTdnn.fromModelDirectory(
            LocalModelManager.directory(for: .spokenLanguageID)
        )
        languageIdentifier = loaded
        return loaded
    }

    private func streamingDiarizationModel() throws -> MLXStreamingSortformerEngine {
        if let streamingDiarizer { return streamingDiarizer }
        let descriptor = LocalModelManager.catalog.first { $0.id == .sortformerDiarization }!
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let loaded = try MLXStreamingSortformerEngine(
            modelDirectory: LocalModelManager.directory(for: .sortformerDiarization),
            modelRevision: descriptor.revision
        )
        streamingDiarizer = loaded
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        Log.transcription.notice(
            "Sortformer model ready revision=\(descriptor.revision) elapsed=\(String(format: "%.2f", elapsed))s"
        )
        return loaded
    }

    private nonisolated static func requireModels(_ ids: [LocalModelID]) throws {
        let missing = ids.compactMap { id -> String? in
            guard let model = LocalModelManager.catalog.first(where: { $0.id == id }) else { return id.rawValue }
            return LocalModelManager.isInstalled(model) ? nil : model.userFacingTitle
        }
        if !missing.isEmpty { throw LocalAIError.missingModels(missing.joined(separator: ", ")) }
    }

    private struct AlignmentSpeechMaskProgress: Sendable {
        let fraction: Double
        let completed: Int?
        let total: Int?
        let message: String
    }

    @concurrent
    private static func makeAlignmentSpeechMask(
        samples: [Float],
        speechRegions: [SpeechRegion],
        progress: @escaping @Sendable (AlignmentSpeechMaskProgress) -> Void
    ) async throws -> AlignmentSpeechMask {
        try Task.checkCancellation()
        let audioDuration = Double(samples.count) / Double(ASRAudioPreprocessor.sampleRate)
        let usesSceneAnalysis = AlignmentSpeechGate.shouldAnalyzeSoundScenes(audioDuration: audioDuration)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        if usesSceneAnalysis {
            progress(.init(
                fraction: 0,
                completed: nil,
                total: nil,
                message: "Analyzing sound scenes for alignment…"
            ))
        } else {
            progress(.init(
                fraction: 1,
                completed: nil,
                total: nil,
                message: "Long recording — skipping sound-scene analysis; preparing alignment…"
            ))
            Log.transcription.notice(
                "Alignment scene analysis skipped audio=\(String(format: "%.1f", audioDuration))s "
                    + "limit=\(String(format: "%.1f", AlignmentSpeechGate.maximumSceneAnalysisDuration))s"
            )
        }
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: ASRAudioPreprocessor.sampleRate,
            speechIntervals: speechRegions.map {
                AlignmentSpeechInterval(startTime: Double($0.startTime), endTime: Double($0.endTime))
            },
            sceneClassifier: usesSceneAnalysis ? SoundAnalysisSceneClassifier() : nil,
            sceneProgress: { completed, total in
                progress(.init(
                    fraction: Double(completed) / Double(max(total, 1)),
                    completed: completed,
                    total: total,
                    message: "Analyzing sound scenes \(completed) of \(total)…"
                ))
            }
        )
        try Task.checkCancellation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let sceneAnalysis = usesSceneAnalysis ? "enabled" : "skipped"
        Log.transcription.notice(
            "Alignment speech mask sceneAnalysis=\(sceneAnalysis) "
                + "audio=\(String(format: "%.1f", audioDuration))s "
                + "elapsed=\(String(format: "%.2f", elapsed))s "
                + "rtf=\(String(format: "%.5f", elapsed / max(audioDuration, 0.001)))"
        )
        return mask
    }

    private struct RecognitionPass: Sendable {
        var spans: [RecognizedSpan]
        var language: String?
        var timestampFallbackCount: Int
        var nativeTokens: [ParakeetTokenAssembler.Token]
    }

    private func recognize(
        samples: [Float],
        chunks: [ASRRecognitionChunk],
        model: LoadedASR,
        parameters: inout STTGenerateParameters,
        engine: ASREngine,
        audioDuration: Double,
        previewsText: Bool = false,
        progressStart: Double,
        progressEnd: Double,
        replayCollector: WhisperProductionReplayCollector? = nil,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void,
        chunkMessage: @Sendable (Int, Int) -> String
    ) throws -> RecognitionPass {
        var spans: [RecognizedSpan] = []
        var nativeTokens: [ParakeetTokenAssembler.Token] = []
        var language: String?
        var timestampFallbackCount = 0
        let span = max(0, progressEnd - progressStart)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let start = max(0, Int((chunk.inputStart * 16_000).rounded(.down)))
            let end = min(samples.count, Int((chunk.inputEnd * 16_000).rounded(.up)))
            guard end > start else { continue }
            let audio = MLXArray(Array(samples[start..<end]))
            if engine == .parakeet, let parakeet = model.parakeet {
                let aligned = parakeet.generateAligned(audio: audio, generationParameters: parameters)
                let regionText = aligned.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !regionText.isEmpty {
                    let owned = ASRRecognitionSpans.ownedChunk(
                        segments: aligned.sentences.map {
                            ASRRecognitionSpans.Segment(
                                text: $0.text,
                                start: $0.start + chunk.inputStart,
                                end: $0.end + chunk.inputStart
                            )
                        },
                        fallbackText: regionText,
                        recognitionStart: chunk.inputStart,
                        recognitionEnd: chunk.inputEnd,
                        ownershipStart: chunk.ownershipStart,
                        ownershipEnd: chunk.ownershipEnd,
                        audioDuration: audioDuration
                    )
                    spans.append(contentsOf: owned.spans)
                    timestampFallbackCount += owned.timestampFallbackCount
                    nativeTokens.append(contentsOf: Self.nativeTokens(
                        from: aligned,
                        chunk: chunk,
                        audioDuration: audioDuration
                    ))
                }
            } else {
                let output: STTOutput
                switch engine {
                case .qwen:
                    guard let qwen = model.qwen else { continue }
                    if previewsText {
                        let prefix = TranscriptSegmenter.joinedText(spans.map(\.text))
                        output = qwen.generate(
                            audio: audio, maxTokens: parameters.maxTokens, temperature: parameters.temperature,
                            language: parameters.language, chunkDuration: parameters.chunkDuration,
                            minChunkDuration: parameters.minChunkDuration,
                            repetitionPenalty: parameters.repetitionPenalty,
                            repetitionContextSize: parameters.repetitionContextSize,
                            onPartialText: { partial in
                                progressUpdate(.init(
                                    stage: .recognizing,
                                    fraction: progressStart + span * Double(index) / Double(max(1, chunks.count)),
                                    message: "Recognizing speech…",
                                    partialText: TranscriptSegmenter.joinedText([prefix, partial])
                                ))
                            }
                        )
                    } else {
                        output = qwen.generate(audio: audio, generationParameters: parameters)
                    }
                case .whisper:
                    guard let whisper = model.whisper else { continue }
                    output = whisper.generate(audio: audio, generationParameters: parameters)
                case .parakeet:
                    continue
                }
                if engine == .whisper {
                    replayCollector?.recordChunk(chunk, output: output, sampleCount: end - start)
                }
                try Task.checkCancellation()
                if previewsText, output.generationTokens >= parameters.maxTokens {
                    throw SpeechInputError.recognitionLimit
                }
                let regionText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !regionText.isEmpty {
                    let owned = ASRRecognitionSpans.ownedChunk(
                        segments: ASRRecognitionSpans.segments(from: output.segments),
                        fallbackText: regionText,
                        recognitionStart: chunk.inputStart,
                        recognitionEnd: chunk.inputEnd,
                        ownershipStart: chunk.ownershipStart,
                        ownershipEnd: chunk.ownershipEnd,
                        audioDuration: audioDuration
                    )
                    spans.append(contentsOf: owned.spans)
                    timestampFallbackCount += owned.timestampFallbackCount
                }
                if language == nil { language = output.language }
                if engine == .qwen, parameters.language == nil,
                   let detected = ASREngineLanguagePolicy.qwenLockLanguage(fromDetected: output.language) {
                    parameters = STTGenerateParameters(
                        maxTokens: parameters.maxTokens,
                        temperature: parameters.temperature,
                        topP: parameters.topP,
                        topK: parameters.topK,
                        verbose: parameters.verbose,
                        language: detected,
                        chunkDuration: parameters.chunkDuration,
                        minChunkDuration: parameters.minChunkDuration,
                        repetitionPenalty: parameters.repetitionPenalty,
                        repetitionContextSize: parameters.repetitionContextSize
                    )
                }
            }
            let completed = index + 1
            progressUpdate(.init(
                stage: .recognizing,
                fraction: progressStart + span * Double(completed) / Double(max(chunks.count, 1)),
                completed: completed,
                total: chunks.count,
                message: chunkMessage(completed, chunks.count)
            ))
        }
        return RecognitionPass(
            spans: spans,
            language: language,
            timestampFallbackCount: timestampFallbackCount,
            nativeTokens: nativeTokens
        )
    }

    private static func timingKey(text: String, start: Double) -> String {
        "\(text)|\(Int((start * 1000).rounded()))"
    }

    private static func timingReferences(_ result: LongFormAlignmentResult) -> [String: WordTimingQuality] {
        var references: [String: WordTimingQuality] = [:]
        for (index, word) in result.words.enumerated() {
            let quality = result.timingQualities.count == result.words.count ? result.timingQualities[index]
                : (result.coarseTimedUnitCount == result.words.count ? .estimated : .aligned)
            references[timingKey(text: word.text, start: Double(word.startTime))] = quality
        }
        return references
    }

    private static func applyingTimingQualities(_ words: [TranscriptionWord], references: [String: WordTimingQuality]) -> [TranscriptionWord] {
        words.map { word in
            guard let start = word.start else { return word }
            return word.withTimingQuality(references[timingKey(text: word.text, start: start)] ?? .unknown)
        }
    }

    private func timedWords(
        spans: [RecognizedSpan],
        nativeWords: [AlignedWord],
        usesNativeTimestamps: Bool,
        language: String,
        aligner: Qwen3ForcedAligner?,
        samples: [Float],
        speechMask: AlignmentSpeechMask,
        progressStart: Double,
        progressEnd: Double,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) throws -> LongFormAlignmentResult {
        if usesNativeTimestamps {
            return LongFormAlignmentResult(
                words: nativeWords,
                coarseTimedUnitCount: 0,
                rejectedAlignmentChunkCount: 0,
                retriedAlignmentChunkCount: 0,
                longestRejectedUnitDuration: nil
            )
        }
        if let aligner {
            return try alignRecognizedSpans(
                spans,
                audio: samples,
                language: language,
                aligner: aligner,
                speechMask: speechMask,
                progressStart: progressStart,
                progressEnd: progressEnd,
                progressUpdate: progressUpdate
            )
        }
        return LongFormAlignmentResult(
            words: spans.map {
                AlignedWord(
                    text: $0.text,
                    startTime: Float($0.startTime),
                    endTime: Float($0.endTime)
                )
            },
            coarseTimedUnitCount: spans.count,
            rejectedAlignmentChunkCount: 0,
            retriedAlignmentChunkCount: 0,
            longestRejectedUnitDuration: nil
        )
    }

    private func alignRecognizedSpans(
        _ spans: [RecognizedSpan],
        audio: [Float],
        language: String,
        aligner: Qwen3ForcedAligner,
        speechMask: AlignmentSpeechMask,
        progressStart: Double,
        progressEnd: Double,
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) throws -> LongFormAlignmentResult {
        let alignmentSpans = try LongFormAlignmentEngine.alignmentChunks(from: spans)
        progressUpdate(.init(
            stage: .aligning,
            fraction: progressStart,
            completed: 0,
            total: alignmentSpans.count,
            message: "Aligning words to the waveform…"
        ))
        let span = max(0, progressEnd - progressStart)
        return try LongFormAlignmentEngine.alignDetailed(
            audio: audio,
            sampleRate: 16_000,
            spans: spans,
            language: language,
            aligner: aligner,
            speechMask: speechMask,
            progress: { fraction, message in
                progressUpdate(.init(
                    stage: .aligning,
                    fraction: progressStart + span * fraction,
                    completed: min(alignmentSpans.count, Int((fraction * Double(alignmentSpans.count)).rounded())),
                    total: alignmentSpans.count,
                    message: message
                ))
            }
        )
    }

    private nonisolated static func lexicalUnitCount(_ spans: [RecognizedSpan]) -> Int {
        spans.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
    }

    private nonisolated static func nativeTokens(
        from result: ParakeetAlignedResult,
        chunk: ASRRecognitionChunk,
        audioDuration: Double
    ) -> [ParakeetTokenAssembler.Token] {
        result.sentences.flatMap(\.tokens).compactMap { token in
            let text = token.text.replacingOccurrences(of: "▁", with: " ")
            guard !text.isEmpty else { return nil }
            let start = token.start + chunk.inputStart
            let end = token.end + chunk.inputStart
            guard end > chunk.ownershipStart, start < chunk.ownershipEnd else { return nil }
            return ParakeetTokenAssembler.Token(
                text: text,
                start: min(audioDuration, max(0, start)),
                end: min(audioDuration, max(start, end))
            )
        }
    }

    private nonisolated static func nativeWords(
        from tokens: [ParakeetTokenAssembler.Token]
    ) -> [AlignedWord] {
        ParakeetTokenAssembler.assemble(tokens).map {
            AlignedWord(
                text: $0.text,
                startTime: Float($0.start),
                endTime: Float($0.end)
            )
        }
    }

    private nonisolated static func promptLanguage(for engine: ASREngine, code: String?) -> String? {
        switch engine {
        case .qwen: ASREngineLanguagePolicy.qwenPromptLanguage(from: code)
        case .parakeet: nil
        case .whisper: ASREngineLanguagePolicy.whisperLanguageCode(from: code)
        }
    }

    private nonisolated static func logRoute(_ route: ASREngineRouteDecision, windowTops: String? = nil) {
        if route.engine == .parakeet,
           let language = route.parakeetDomainLanguage,
           ASREngineLanguagePolicy.parakeetQualityWatchLanguages.contains(language) {
            Log.transcription.notice("QUALITY_WATCH parakeet language=\(language)")
        }
        var message = "ASR engine route engine=\(route.engine.rawValue) reason=\(route.reason.rawValue) "
            + "qCoverage=\(String(format: "%.2f", route.scores.qwen)) "
            + "pCoverage=\(String(format: "%.2f", route.scores.parakeet)) "
            + "uncovered=\(String(format: "%.2f", route.scores.whisper)) "
            + "qVote=\(String(format: "%.2f", route.engineVoteScores.qwen)) "
            + "pVote=\(String(format: "%.2f", route.engineVoteScores.parakeet)) "
            + "wVote=\(String(format: "%.2f", route.engineVoteScores.whisper)) "
            + "top=\(route.topLanguage ?? "nil") "
            + "hint=\(route.whisperHint ?? "nil") "
            + "prompt=\(ASREngineLanguagePolicy.decoderLanguagePrompt(for: route) ?? "nil") "
            + "window=\(String(format: "%.1f", route.speechDuration))s"
        if let windowTops {
            message += " windows=\(windowTops)"
        }
        if let vote = route.languageVote {
            message += " strategy=engine_coverage scoreKind=equal_valid_window_uncalibrated_posterior"
                + " pooled=\(vote.confidence) margin=\(vote.margin) anchors=\(vote.anchorLanguages.joined(separator: ","))"
                + " validWindows=\(vote.validWindowCount) invalidWindows=\(vote.invalidWindowCount)"
                + " shares=\(vote.weightShares)"
                + " windowCoverage=\(vote.windowPosteriors.map { ASREngineRouter.scores(from: $0) })"
        }
        Log.transcription.notice(message)
    }

    private nonisolated static func routeAutomaticEngine(
        samples: [Float],
        speechRanges: [ASRSpeechRange],
        languageIdentifier: EcapaTdnn
    ) throws -> ASREngineRouteDecision {
        let evidence = try languageIdentificationEvidence(
            samples: samples, speechRanges: speechRanges, languageIdentifier: languageIdentifier
        )
        let route = ASREngineRouter.decide(evidence: evidence)
        logRoute(route)
        return route
    }

    nonisolated static func languageIdentificationEvidence(
        samples: [Float],
        speechRanges: [ASRSpeechRange],
        languageIdentifier: EcapaTdnn
    ) throws -> [ASRLanguageEvidence] {
        let audioDuration = Double(samples.count) / Double(ASRAudioPreprocessor.sampleRate)
        let windows = ASREngineRouter.identificationWindows(
            speechRanges: speechRanges,
            audioDuration: audioDuration
        )
        return try languageIdentificationEvidence(
            samples: samples,
            windows: windows,
            languageIdentifier: languageIdentifier
        )
    }

    nonisolated static func sampledLanguageIdentificationEvidence(
        samples: [Float],
        languageIdentifier: EcapaTdnn
    ) throws -> (evidence: [ASRLanguageEvidence], sampling: ASRLanguageClipSamplingResult) {
        let sampling = ASRLanguageClipSampler.windows(samples: samples)
        let evidence = try languageIdentificationEvidence(
            samples: samples,
            windows: sampling.windows,
            languageIdentifier: languageIdentifier
        )
        return (evidence, sampling)
    }

    private nonisolated static func languageIdentificationEvidence(
        samples: [Float],
        windows: [ASRLanguageIdentificationWindow],
        languageIdentifier: EcapaTdnn
    ) throws -> [ASRLanguageEvidence] {
        var evidence: [ASRLanguageEvidence] = []
        evidence.reserveCapacity(windows.count)
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let waveform = languageDetectionSamples(from: samples, window: window)
            guard !waveform.isEmpty else { continue }
            let posterior = languageIdentifier.posterior(waveform: MLXArray(waveform))
            evidence.append(.init(window: window, posterior: posterior))
            let top = ASREngineRouter.topLanguage(in: posterior)
            let label = top.map { "\($0.language):\(String(format: "%.2f", $0.confidence))" } ?? "nil"
            Log.transcription.notice(
                "ASR LID window \(index + 1)/\(windows.count) "
                    + "start=\(String(format: "%.1f", window.start))s "
                    + "duration=\(String(format: "%.1f", window.duration))s top=\(label)"
            )
        }
        try Task.checkCancellation()
        return evidence
    }

    private nonisolated static func languageDetectionSamples(
        from samples: [Float],
        window: ASRLanguageIdentificationWindow
    ) -> [Float] {
        let sampleRate = Double(ASRAudioPreprocessor.sampleRate)
        var selected: [Float] = []
        let expected = max(1, Int((window.duration * sampleRate).rounded(.down)))
        selected.reserveCapacity(min(samples.count, expected))
        for slice in window.slices {
            let start = min(samples.count, max(0, Int((slice.start * sampleRate).rounded(.down))))
            let end = min(samples.count, max(start, Int((slice.end * sampleRate).rounded(.up))))
            guard end > start else { continue }
            selected.append(contentsOf: samples[start..<end])
        }
        return selected
    }

    private nonisolated static func alignerLanguage(from code: String?) -> String {
        guard let code else { return "English" }
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        return [
            "zh": "Chinese", "yue": "Cantonese", "en": "English", "ja": "Japanese",
            "ko": "Korean", "es": "Spanish", "fr": "French", "de": "German",
            "it": "Italian", "pt": "Portuguese", "ru": "Russian", "ar": "Arabic",
            "hi": "Hindi", "id": "Indonesian", "vi": "Vietnamese", "th": "Thai",
        ][base] ?? Locale(identifier: "en").localizedString(forLanguageCode: base) ?? "English"
    }

    nonisolated static func detectLanguageCode(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    nonisolated static func assignSpeakers(
        to aligned: [AlignedWord],
        timeline: SpeakerActivityTimeline,
        audioDuration: Double,
        languageCode: String? = nil,
        policy: SpeakerDiarizationPolicy = .standard(requestedSpeakerCount: nil)
    ) -> [TranscriptionWord] {
        LexicalSpeakerResolver.assignSpeakers(
            to: aligned,
            timeline: timeline,
            audioDuration: audioDuration,
            languageCode: languageCode,
            policy: policy
        )
    }

    /// Forced aligners can return zero-width tokens or extend slightly beyond the
    /// decoded waveform, especially at AAC padding boundaries. Normalize once at
    /// the pipeline boundary so captions, word highlighting, and word-based edits
    /// all receive monotonic, positive, in-range spans.
    nonisolated static func normalizedWordTiming(
        start rawStart: Double,
        end rawEnd: Double,
        previousStart: Double,
        audioDuration: Double
    ) -> (start: Double, end: Double) {
        let duration = max(0, audioDuration)
        let minimumSpan = min(0.02, duration)
        let latestStart = max(0, duration - minimumSpan)
        var start = min(latestStart, max(previousStart, max(0, rawStart)))
        var end = min(duration, max(start, rawEnd))

        if end - start < minimumSpan {
            if start + minimumSpan <= duration {
                end = start + minimumSpan
            } else {
                start = max(previousStart, duration - minimumSpan)
                end = duration
            }
        }
        return (start, end)
    }

    nonisolated static func makeSegments(from words: [TranscriptionWord]) -> [TranscriptionSegment] {
        TranscriptSegmenter.aggregate(words: words)
    }
    #endif
}

actor LocalDubPipeline {
    static let shared = LocalDubPipeline()

    #if BUNDLED_SPEECH
    private var loadedModels: [LocalModelID: MLXAudioTTS.Qwen3TTSModel] = [:]
    #endif

    func synthesize(
        script: String,
        language: String,
        model choice: DubModelChoice,
        referenceAudioURL: URL?,
        referenceText: String,
        seed: UInt64 = 0,
        xvecOnly: Bool = false,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        #if BUNDLED_SPEECH
        _ = xvecOnly
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalAIError.emptyTranscript }
        guard let descriptor = LocalModelManager.catalog.first(where: { $0.id == choice.modelID }),
              LocalModelManager.isInstalled(descriptor) else {
            throw LocalAIError.missingModels(choice.label)
        }
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }

        progress(0.08, "Loading \(choice.label)…")
        let referenceTranscript = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try await loadModel(
            choice.modelID,
            descriptor: descriptor,
            progress: progress
        )

        progress(0.30, referenceAudioURL == nil ? "Synthesizing speech…" : "Cloning reference voice…")
        let normalizedLanguage = Self.ttsLanguage(language, script: text)
        let samples = try await renderedSamples()
        guard !samples.isEmpty else { throw LocalAIError.noAudioOutput }
        progress(0.92, "Writing local WAV…")
        let output = try Self.writeWAV(samples)
        progress(1, "Dub ready")
        return output

        func renderedSamples() async throws -> [Float] {
            let audio: MLXArray
            if let referenceAudioURL {
                let referenceSamples = try AudioFileLoader.load(
                    url: referenceAudioURL,
                    targetSampleRate: model.sampleRate
                )
                let reference = MLXArray(referenceSamples)
                MLXRandom.seed(seed)
                audio = try await model.generate(
                    text: text,
                    voice: nil,
                    refAudio: reference,
                    refText: referenceTranscript.isEmpty ? nil : referenceTranscript,
                    language: normalizedLanguage
                )
            } else {
                MLXRandom.seed(seed)
                audio = try await model.generate(
                    text: text,
                    voice: nil,
                    refAudio: nil,
                    refText: nil,
                    language: normalizedLanguage
                )
            }
            return audio.asArray(Float.self)
        }
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    func releaseLane() async {
        #if BUNDLED_SPEECH
        let hadModel = !loadedModels.isEmpty
        guard hadModel else { return }
        do {
            try await MLXRuntime.beginInference()
        } catch {
            loadedModels.removeAll()
            return
        }
        defer { MLXRuntime.endInference() }
        loadedModels.removeAll()
        MLXRuntime.releaseActivations()
        #endif
    }

    #if BUNDLED_SPEECH
    private func loadModel(
        _ id: LocalModelID,
        descriptor: LocalModelDescriptor,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MLXAudioTTS.Qwen3TTSModel {
        if let cached = loadedModels[id] {
            return cached
        }

        let modelDirectory = try await Self.prepareMLXAudioModelDirectory(
            for: id,
            descriptor: descriptor
        )
        guard let model = try await TTS.loadModel(modelRepo: modelDirectory.path)
            as? MLXAudioTTS.Qwen3TTSModel else {
            throw LocalAIError.incompleteModel(descriptor.userFacingTitle)
        }
        loadedModels[id] = model
        progress(0.26, "Local voice ready")
        return model
    }

    private nonisolated static func prepareMLXAudioModelDirectory(
        for id: LocalModelID,
        descriptor: LocalModelDescriptor
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let source = try LocalModelManager.directory(for: id)
            let tokenizer = try HuggingFaceDownloader.getCacheDirectory(
                for: LocalModelManager.ttsTokenizerRepository
            )
            let base = AppSupportPaths.caches()
                .appendingPathComponent("MLXAudioTTS", isDirectory: true)
            let directory = base.appendingPathComponent(
                "\(id.rawValue)-\(descriptor.revision)",
                isDirectory: true
            )
            let fileManager = FileManager.default

            if Self.isReadyMLXAudioModelDirectory(directory, tokenizer: tokenizer) {
                return directory
            }

            let staging = base.appendingPathComponent(
                ".\(id.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                let sourceFiles = try fileManager.contentsOfDirectory(
                    at: source,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for sourceFile in sourceFiles where sourceFile.lastPathComponent != "config.json" {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(
                        atPath: sourceFile.path,
                        isDirectory: &isDirectory
                    ), !isDirectory.boolValue else { continue }
                    try fileManager.createSymbolicLink(
                        at: staging.appendingPathComponent(sourceFile.lastPathComponent),
                        withDestinationURL: sourceFile
                    )
                }

                let configURL = source.appendingPathComponent("config.json")
                var config = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: configURL),
                    options: []
                ) as? [String: Any] ?? [:]
                var speakerEncoderConfig = config["speaker_encoder_config"] as? [String: Any] ?? [:]
                speakerEncoderConfig["enc_dim"] = 2048
                speakerEncoderConfig["sample_rate"] = 24_000
                config["speaker_encoder_config"] = speakerEncoderConfig
                config["tts_model_type"] = config["tts_model_type"] ?? "base"
                config["sample_rate"] = config["sample_rate"] ?? 24_000
                let normalizedConfig = try JSONSerialization.data(
                    withJSONObject: config,
                    options: [.sortedKeys]
                )
                try normalizedConfig.write(
                    to: staging.appendingPathComponent("config.json"),
                    options: .atomic
                )

                let speechTokenizer = staging.appendingPathComponent(
                    "speech_tokenizer",
                    isDirectory: true
                )
                try fileManager.createDirectory(
                    at: speechTokenizer,
                    withIntermediateDirectories: true
                )
                let tokenizerFiles = try fileManager.contentsOfDirectory(
                    at: tokenizer,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for tokenizerFile in tokenizerFiles {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(
                        atPath: tokenizerFile.path,
                        isDirectory: &isDirectory
                    ), !isDirectory.boolValue else { continue }
                    try fileManager.createSymbolicLink(
                        at: speechTokenizer.appendingPathComponent(tokenizerFile.lastPathComponent),
                        withDestinationURL: tokenizerFile
                    )
                }

                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
                try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
                try fileManager.moveItem(at: staging, to: directory)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            return directory
        }.value
    }

    private nonisolated static func isReadyMLXAudioModelDirectory(
        _ directory: URL,
        tokenizer: URL
    ) -> Bool {
        let fileManager = FileManager.default
        let speechTokenizerPath = directory.appendingPathComponent(
            "speech_tokenizer",
            isDirectory: true
        )
        var isSpeechTokenizerDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path),
              fileManager.fileExists(
                  atPath: speechTokenizerPath.path,
                  isDirectory: &isSpeechTokenizerDirectory
              ),
              isSpeechTokenizerDirectory.boolValue,
              (try? fileManager.destinationOfSymbolicLink(atPath: speechTokenizerPath.path)) == nil,
              fileManager.fileExists(atPath: speechTokenizerPath.appendingPathComponent("config.json").path),
              fileManager.fileExists(atPath: tokenizer.appendingPathComponent("model.safetensors").path),
              let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let speakerEncoderConfig = config["speaker_encoder_config"] as? [String: Any],
              speakerEncoderConfig["enc_dim"] as? Int == 2048 else {
            return false
        }
        return true
    }

    nonisolated static func ttsLanguage(_ value: String, script: String) -> String {
        var normalized = value.lowercased()
        if normalized == "auto" || normalized.isEmpty {
            normalized = LocalSpeechPipeline.detectLanguageCode(in: script) ?? "en"
        }
        normalized = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return [
            "en": "english", "zh": "chinese", "yue": "cantonese", "ja": "japanese",
            "ko": "korean", "es": "spanish", "fr": "french", "de": "german",
            "it": "italian", "pt": "portuguese", "ru": "russian",
        ][normalized] ?? normalized
    }

    private nonisolated static func writeWAV(_ samples: [Float]) throws -> URL {
        let directory = AppSupportPaths.applicationSupport()
            .appendingPathComponent("Dubs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dub-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw LocalAIError.noAudioOutput
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    #endif
}
