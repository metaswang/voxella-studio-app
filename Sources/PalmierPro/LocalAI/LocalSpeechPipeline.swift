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

    init(
        stage: LocalSpeechStage,
        fraction: Double,
        completed: Int? = nil,
        total: Int? = nil,
        message: String
    ) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
        self.completed = completed
        self.total = total
        self.message = message
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
        #if BUNDLED_SPEECH
        let whisperFallbackModelID = LocalModelManager.preferredWhisperFallbackModelID()
        let requiredModels = LocalModelInstallPlan.requiredModelIDs(
            languageCode: languageCode,
            speakerCount: speakerCount,
            whisperFallbackModelID: whisperFallbackModelID
        )
        try Self.requireModels(requiredModels)
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }

        progressUpdate(.init(stage: .decoding, fraction: 0.03, message: "Decoding audio locally…"))
        let preparationStartedAt = DispatchTime.now().uptimeNanoseconds
        let preparedURL = try await DecodedAudioCache.file(for: sourceURL, range: clipRangeSeconds)
        let decodedSamples = try AudioFileLoader.load(url: preparedURL, targetSampleRate: ASRAudioPreprocessor.sampleRate)
        let preprocessing = ASRAudioPreprocessor.prepare(samples: decodedSamples)
        guard !decodedSamples.isEmpty else { throw LocalAIError.noAudioSamples }
        guard !preprocessing.original.isEffectivelySilent else {
            throw LocalAIError.audioTooQuiet
        }
        if preprocessing.didApplyGain {
            progressUpdate(.init(
                stage: .decoding,
                fraction: 0.05,
                message: String(format: "Enhancing low-level audio (+%.1f dB)…", preprocessing.appliedGainDB)
            ))
        }
        let samples = preprocessing.samples
        let originalMetrics = preprocessing.original
        let processedMetrics = preprocessing.processed
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
            preprocessing.appliedGainDB
        )
        Log.transcription.notice(levelMessage)

        let vadTotalChunks = LocalSpeechVADRunner.chunkCount(for: samples.count)
        progressUpdate(.init(
            stage: .detectingSpeech,
            fraction: 0.07,
            completed: 0,
            total: vadTotalChunks,
            message: "Checking for speech locally…"
        ))

        let analysis = try await SpeechAnalysisService.shared.analyze(
            samples: samples,
            progress: { completed, total, message in
                let fraction = 0.07 + 0.03 * (Double(completed) / Double(max(1, total)))
                progressUpdate(.init(
                    stage: .detectingSpeech,
                    fraction: fraction,
                    completed: completed,
                    total: total,
                    message: message
                ))
            }
        )
        try Task.checkCancellation()
        var speechRegions = analysis.segments
        if speechRegions.isEmpty {
            Log.transcription.warning(
                "VAD returned no regions after ASR preprocessing; using full-audio fallback rms=\(String(format: "%.1f", processedMetrics.rmsDBFS))dBFS peak=\(String(format: "%.1f", processedMetrics.peakDBFS))dBFS"
            )
            speechRegions = [SpeechRegion(
                startTime: 0,
                endTime: Float(Double(samples.count) / Double(ASRAudioPreprocessor.sampleRate))
            )]
        }
        guard !speechRegions.isEmpty else {
            throw LocalAIError.vadNoSpeech
        }

        let requestedLanguage = TranscriptionLanguage(code: languageCode)
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
            progressUpdate(.init(stage: .detectingLanguage, fraction: 0.10, message: "Selecting ASR engine locally…"))
            route = Self.routeAutomaticEngine(
                samples: samples,
                speechRegions: speechRegions,
                languageIdentifier: try languageIdentifierModel()
            )
            recognitionLanguageCode = Self.automaticPromptLanguage(for: route)
            outputLanguageCode = Self.outputLanguage(for: route)
            progressUpdate(.init(
                stage: .detectingLanguage,
                fraction: 0.12,
                message: String(
                    format: "Using \(route.engine.title) (%@, q=%.2f p=%.2f w=%.2f)…",
                    route.reason.rawValue,
                    route.scores.qwen,
                    route.scores.parakeet,
                    route.scores.whisper
                )
            ))
        }

        let audioDuration = Double(samples.count) / 16_000
        let speechMask = Self.makeAlignmentSpeechMask(samples: samples, speechRegions: speechRegions)
        let asrModelID = ASREngineLanguagePolicy.modelID(
            for: route.engine,
            whisperFallback: whisperFallbackModelID
        )
        guard let asrDescriptor = LocalModelManager.catalog.first(where: { $0.id == asrModelID }) else {
            throw LocalAIError.modelsUnavailable
        }
        let chunkConfiguration: ASRChunkPlannerConfiguration
        if route.engine == .whisper, let specification = asrDescriptor.asrSpecification {
            chunkConfiguration = ASRChunkPlannerConfiguration(
                maximumWindowDuration: specification.maximumWindowDuration,
                boundaryContextDuration: specification.boundaryContextDuration,
                maximumMergeGap: specification.maximumMergeGap
            )
        } else {
            chunkConfiguration = route.engine.chunkConfiguration
        }
        let recognitionChunks = ASRChunkPlanner.chunks(
            speechRanges: speechRegions.map {
                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
            },
            audioDuration: audioDuration,
            configuration: chunkConfiguration
        )
        guard !recognitionChunks.isEmpty else { throw LocalAIError.vadNoSpeech }
        Log.transcription.notice(
            "ASR chunks engine=\(route.engine.rawValue) count=\(recognitionChunks.count) "
                + "window=\(String(format: "%.0f", chunkConfiguration.maximumWindowDuration))s "
                + "audio=\(String(format: "%.1f", audioDuration))s"
        )

        progressUpdate(.init(stage: .recognizing, fraction: 0.14, message: "Loading \(asrDescriptor.title)…"))
        let loadedASR = try await asrModel(id: asrModelID, engine: route.engine)
        var parameters = loadedASR.defaultParameters
        parameters = STTGenerateParameters(
            maxTokens: parameters.maxTokens,
            temperature: 0,
            topP: parameters.topP,
            topK: parameters.topK,
            verbose: false,
            language: recognitionLanguageCode,
            chunkDuration: route.engine == .parakeet ? 120 : parameters.chunkDuration,
            minChunkDuration: parameters.minChunkDuration,
            repetitionPenalty: parameters.repetitionPenalty,
            repetitionContextSize: parameters.repetitionContextSize
        )

        progressUpdate(.init(
            stage: .recognizing,
            fraction: 0.20,
            completed: 0,
            total: recognitionChunks.count,
            message: "Recognizing speech with \(asrDescriptor.title)…"
        ))
        var recognition = try recognize(
            samples: samples,
            chunks: recognitionChunks,
            model: loadedASR,
            parameters: &parameters,
            engine: route.engine,
            audioDuration: audioDuration,
            progressStart: 0.20,
            progressEnd: 0.50,
            progressUpdate: progressUpdate,
            chunkMessage: { "Recognizing speech chunk \($0) of \($1)…" }
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
            languageCode: qualityLanguageCode
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

        let uncovered = ASRCoverageRepair.uncoveredSpeech(
            mask: speechMask,
            covered: aligned.map {
                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
            }
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
                audioDuration: audioDuration
            )
            Log.transcription.notice(
                "coverage retry cores=\(retriedUncoveredRangeCount) seconds=\(String(format: "%.1f", retriedUncoveredSpeechSeconds))"
            )
            let retryChunks = ASRChunkPlanner.chunks(
                speechRanges: retryInputs,
                audioDuration: audioDuration,
                configuration: chunkConfiguration
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
                            languageCode: qualityLanguageCode ?? resolvedLanguageCode
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
                                Log.transcription.notice("coverage retry did not improve core coverage; keeping first pass")
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
        let timeline: SpeakerActivityTimeline
        if speakerCount == 1 {
            progressUpdate(.init(stage: .assigningSpeakers, fraction: 0.90, message: "Assigning the single speaker locally…"))
            timeline = SpeakerActivityPostprocessor.singleSpeaker(
                speechRanges: speechRanges,
                audioDuration: audioDuration
            )
        } else {
            progressUpdate(.init(stage: .diarizing, fraction: diarizeStart, message: "Loading streaming speaker model…"))
            let diarizer = try streamingDiarizationModel()
            timeline = try await diarizer.diarize(
                audio: samples,
                sampleRate: 16_000,
                speechRanges: speechRanges,
                policy: diarizationPolicy,
                progress: { update in
                    progressUpdate(.init(
                        stage: .diarizing,
                        fraction: diarizeStart + update.fraction * diarizeSpan,
                        completed: update.completed,
                        total: update.total,
                        message: update.message
                    ))
                }
            )
            try Task.checkCancellation()
        }
        let assignStartedAt = DispatchTime.now().uptimeNanoseconds
        let attributed = Self.assignSpeakers(
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
        let qualityStartedAt = DispatchTime.now().uptimeNanoseconds
        let words = TranscriptionQualityProcessor.postprocess(
            attributed,
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
            finalLexicalUnitCount: words.count
        )
        return LocalTranscriptionOutput(
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
        )
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

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
        progressUpdate: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> KnownTextAlignmentOutput {
        #if BUNDLED_SPEECH
        let script = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { throw LocalAIError.emptyTranscript }
        var requiredModels: [LocalModelID] = [.forcedAligner, .sileroVAD]
        if case .diarize(let requestedSpeakerCount) = request.speakerAttribution,
           requestedSpeakerCount != 1 {
            requiredModels.append(.sortformerDiarization)
        }
        try Self.requireModels(requiredModels)
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }

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
            samples: samples,
            progress: { _, _, _ in }
        )
        var speechRegions = vadAnalysis.segments
        if speechRegions.isEmpty {
            Log.transcription.warning("alignment VAD returned no regions after ASR preprocessing; using full-audio fallback")
            speechRegions = [SpeechRegion(startTime: 0, endTime: Float(audioDuration))]
        }
        let speechMask = Self.makeAlignmentSpeechMask(samples: samples, speechRegions: speechRegions)
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
        switch request.speakerAttribution {
        case .providedSpans:
            words = KnownTextSpeakerMapper.assign(words: untitledWords, spans: request.spans)
        case .none:
            words = untitledWords
        case .diarize(let requestedSpeakerCount):
            if requestedSpeakerCount == 1 {
                words = untitledWords.map {
                    TranscriptionWord(
                        text: $0.text,
                        start: $0.start,
                        end: $0.end,
                        speaker: "Speaker 1",
                        speakerConfidence: 1
                    )
                }
            } else {
                Memory.clearCache()
                let speechRanges = speechRegions.map {
                    SpeechTimeRange(start: Double($0.startTime), end: Double($0.endTime))
                }
                let diarizer = try streamingDiarizationModel()
                let diarizationPolicy = SpeakerDiarizationPolicy.standard(
                    requestedSpeakerCount: requestedSpeakerCount
                )
                let timeline = try await diarizer.diarize(
                    audio: samples,
                    sampleRate: 16_000,
                    speechRanges: speechRanges,
                    policy: diarizationPolicy,
                    progress: { update in
                        progressUpdate(.init(
                            stage: .diarizing,
                            fraction: 0.84 + update.fraction * 0.12,
                            completed: update.completed,
                            total: update.total,
                            message: update.message
                        ))
                    }
                )
                let assignStartedAt = DispatchTime.now().uptimeNanoseconds
                words = Self.assignSpeakers(
                    to: aligned.words,
                    timeline: timeline,
                    audioDuration: audioDuration,
                    languageCode: resolvedLanguageCode,
                    policy: diarizationPolicy
                )
                let assignElapsed = Double(
                    DispatchTime.now().uptimeNanoseconds - assignStartedAt
                ) / 1_000_000_000
                Log.transcription.notice(
                    "Script speaker assignment elapsed=\(String(format: "%.2f", assignElapsed))s words=\(words.count)"
                )
            }
        }
        progressUpdate(.init(stage: .finalizing, fraction: 0.98, message: "Building timed script segments…"))
        let result = TranscriptionResult(
            text: script,
            language: resolvedLanguageCode,
            words: words,
            segments: Self.makeSegments(from: words)
        )
        progressUpdate(.init(stage: .finalizing, fraction: 1, message: "Script alignment ready"))
        return KnownTextAlignmentOutput(
            result: result,
            diagnostics: KnownTextAlignmentDiagnostics(
                alignedUnitCount: aligned.words.count,
                estimatedUnitCount: aligned.coarseTimedUnitCount
            )
        )
        #else
        throw LocalAIError.modelsUnavailable
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
        whisper = nil
        qwen = nil
        parakeet = nil
        Memory.clearCache()
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
            return LocalModelManager.isInstalled(model) ? nil : model.title
        }
        if !missing.isEmpty { throw LocalAIError.missingModels(missing.joined(separator: ", ")) }
    }

    private nonisolated static func makeAlignmentSpeechMask(
        samples: [Float],
        speechRegions: [SpeechRegion]
    ) -> AlignmentSpeechMask {
        AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: 16_000,
            speechIntervals: speechRegions.map {
                AlignmentSpeechInterval(startTime: Double($0.startTime), endTime: Double($0.endTime))
            },
            sceneClassifier: SoundAnalysisSceneClassifier()
        )
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
        progressStart: Double,
        progressEnd: Double,
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
                    output = qwen.generate(audio: audio, generationParameters: parameters)
                case .whisper:
                    guard let whisper = model.whisper else { continue }
                    output = whisper.generate(audio: audio, generationParameters: parameters)
                case .parakeet:
                    continue
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
                coarseTimedUnitCount: nativeWords.count,
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

    private nonisolated static func outputLanguage(for route: ASREngineRouteDecision) -> String? {
        switch route.engine {
        case .qwen: nil
        case .parakeet: route.parakeetDomainLanguage
        case .whisper: route.whisperHint
        }
    }

    private nonisolated static func logRoute(_ route: ASREngineRouteDecision, windowTops: String? = nil) {
        if route.engine == .parakeet,
           let language = route.parakeetDomainLanguage,
           ASREngineLanguagePolicy.parakeetQualityWatchLanguages.contains(language) {
            Log.transcription.notice("QUALITY_WATCH parakeet language=\(language)")
        }
        var message = "ASR engine route engine=\(route.engine.rawValue) reason=\(route.reason.rawValue) "
            + "q=\(String(format: "%.2f", route.scores.qwen)) "
            + "p=\(String(format: "%.2f", route.scores.parakeet)) "
            + "w=\(String(format: "%.2f", route.scores.whisper)) "
            + "top=\(route.topLanguage ?? "nil") "
            + "window=\(String(format: "%.1f", route.speechDuration))s"
        if let windowTops {
            message += " windows=\(windowTops)"
        }
        Log.transcription.notice(message)
    }

    private nonisolated static func automaticPromptLanguage(for route: ASREngineRouteDecision) -> String? {
        switch route.engine {
        case .qwen, .parakeet: nil
        case .whisper: route.whisperHint
        }
    }

    private nonisolated static func routeAutomaticEngine(
        samples: [Float],
        speechRegions: [SpeechRegion],
        languageIdentifier: EcapaTdnn
    ) -> ASREngineRouteDecision {
        let audioDuration = Double(samples.count) / Double(ASRAudioPreprocessor.sampleRate)
        let windows = ASREngineRouter.identificationWindows(
            speechRanges: speechRegions.map {
                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
            },
            audioDuration: audioDuration
        )
        let sampledWindows = windows.isEmpty
            ? [ASRLanguageIdentificationWindow(slices: [
                ASRSpeechRange(start: 0, end: min(audioDuration, ASREngineRouter.shortWindowDuration))
            ])]
            : windows
        var posteriors: [[String: Float]] = []
        var tops: [String] = []
        posteriors.reserveCapacity(sampledWindows.count)
        for (index, window) in sampledWindows.enumerated() {
            let waveform = languageDetectionSamples(from: samples, window: window)
            guard !waveform.isEmpty else { continue }
            let posterior = languageIdentifier.posterior(waveform: MLXArray(waveform))
            posteriors.append(posterior)
            let top = ASREngineRouter.topLanguage(in: posterior)
            let label = top.map { "\($0.language):\(String(format: "%.2f", $0.confidence))" } ?? "nil"
            tops.append(label)
            Log.transcription.notice(
                "ASR LID window \(index + 1)/\(sampledWindows.count) "
                    + "start=\(String(format: "%.1f", window.start))s "
                    + "duration=\(String(format: "%.1f", window.duration))s top=\(label)"
            )
        }
        let sampledDuration = sampledWindows.reduce(0.0) { $0 + $1.duration }
        let route = ASREngineRouter.decide(
            windowPosteriors: posteriors,
            speechDuration: max(sampledDuration, ASREngineRouter.minimumSpeechDuration)
        )
        logRoute(route, windowTops: "\(posteriors.count):\(tops.joined(separator: ","))")
        return route
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

        progress(0.08, "Loading \(choice.label)…")
        let referenceTranscript = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try await loadModel(
            choice.modelID,
            descriptor: descriptor,
            progress: progress
        )

        progress(0.30, referenceAudioURL == nil ? "Synthesizing speech…" : "Cloning reference voice…")
        let normalizedLanguage = Self.ttsLanguage(language, script: text)
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
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty else { throw LocalAIError.noAudioOutput }
        progress(0.92, "Writing local WAV…")
        let output = try Self.writeWAV(samples)
        progress(1, "Dub ready")
        return output
        #else
        throw LocalAIError.modelsUnavailable
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
            throw LocalAIError.incompleteModel(descriptor.title)
        }
        loadedModels[id] = model
        progress(0.26, "Loaded \(descriptor.title)")
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
