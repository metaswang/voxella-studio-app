import AVFoundation
import Foundation
import NaturalLanguage

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import MLXAudioLID
import MLXAudioSTT
import MLXAudioTTS
import MLXAudioVAD
import Qwen3ASR
import SpeechVAD
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
}

actor LocalSpeechPipeline {
    static let shared = LocalSpeechPipeline()

    #if BUNDLED_SPEECH
    private var whisper: (id: LocalModelID, model: WhisperModel)?
    private var languageIdentifier: EcapaTdnn?
    private var aligner: Qwen3ForcedAligner?
    private var vad: SileroVADModel?
    private var streamingDiarizer: MLXStreamingSortformerEngine?
    private var diarizer: PyannoteDiarizationPipeline?
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
        let asrModelID = LocalModelManager.preferredASRModelID()
        guard let asrDescriptor = LocalModelManager.catalog.first(where: { $0.id == asrModelID }),
              let asrSpecification = asrDescriptor.asrSpecification else {
            throw LocalAIError.modelsUnavailable
        }
        var requiredModels: [LocalModelID] = [
            asrModelID,
            .forcedAligner,
            .sileroVAD,
        ]
        if speakerCount != 1 {
            requiredModels.append(.sortformerDiarization)
        }
        if languageCode == nil { requiredModels.append(.spokenLanguageID) }
        try Self.requireModels(requiredModels)
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }

        progressUpdate(.init(stage: .decoding, fraction: 0.03, message: "Decoding audio locally…"))
        let preparedURL: URL
        let shouldRemovePrepared: Bool
        let needsExtraction = clipRangeSeconds != nil
            || ClipType(fileExtension: sourceURL.pathExtension.lowercased()) == .video
        if needsExtraction {
            preparedURL = try await Transcription.extractAudioTrack(
                from: sourceURL,
                range: clipRangeSeconds
            )
            shouldRemovePrepared = true
        } else {
            preparedURL = sourceURL
            shouldRemovePrepared = false
        }
        defer {
            if shouldRemovePrepared { try? FileManager.default.removeItem(at: preparedURL) }
        }

        let samples = try AudioFileLoader.load(url: preparedURL, targetSampleRate: 16_000)
        guard !samples.isEmpty else { throw LocalAIError.emptyTranscript }

        progressUpdate(.init(stage: .detectingSpeech, fraction: 0.07, message: "Checking for speech locally…"))
        let vad = try await vadModel()
        let speechRegions = vad.detectSpeech(audio: samples, sampleRate: 16_000)
        guard !speechRegions.isEmpty else {
            throw LocalAIError.emptyTranscript
        }

        let requestedLanguage = TranscriptionLanguage(code: languageCode)
        let recognitionLanguageCode: String?
        let outputLanguageCode: String?
        if languageCode != nil {
            recognitionLanguageCode = requestedLanguage.asrLanguageCode
            outputLanguageCode = requestedLanguage.outputLanguageCode
        } else {
            progressUpdate(.init(stage: .detectingLanguage, fraction: 0.10, message: "Detecting spoken language locally…"))
            let languageSamples = Self.languageDetectionSamples(from: samples, speechRegions: speechRegions)
            let prediction = try languageIdentifierModel().predict(
                waveform: MLXArray(languageSamples),
                topK: 3
            )
            let detectedLanguage = prediction.language == "unknown" ? nil : prediction.language
            let detected = TranscriptionLanguage(code: detectedLanguage)
            recognitionLanguageCode = detected.asrLanguageCode
            outputLanguageCode = detected.outputLanguageCode
        }

        let recognitionChunks = ASRChunkPlanner.chunks(
            speechRanges: speechRegions.map {
                ASRSpeechRange(start: Double($0.startTime), end: Double($0.endTime))
            },
            audioDuration: Double(samples.count) / 16_000,
            configuration: .init(
                maximumWindowDuration: asrSpecification.maximumWindowDuration,
                boundaryContextDuration: asrSpecification.boundaryContextDuration,
                maximumMergeGap: asrSpecification.maximumMergeGap
            )
        )
        guard !recognitionChunks.isEmpty else { throw LocalAIError.emptyTranscript }

        progressUpdate(.init(stage: .recognizing, fraction: 0.14, message: "Loading \(asrDescriptor.title)…"))
        let whisper = try await whisperModel(id: asrModelID)
        var parameters = whisper.defaultGenerationParameters
        parameters = STTGenerateParameters(
            maxTokens: parameters.maxTokens,
            temperature: 0,
            topP: parameters.topP,
            topK: parameters.topK,
            verbose: false,
            language: recognitionLanguageCode,
            chunkDuration: parameters.chunkDuration,
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
        var recognizedSpans: [RecognizedSpan] = []
        var whisperLanguage: String?
        for (index, chunk) in recognitionChunks.enumerated() {
            try Task.checkCancellation()
            let start = max(0, Int((chunk.inputStart * 16_000).rounded(.down)))
            let end = min(samples.count, Int((chunk.inputEnd * 16_000).rounded(.up)))
            guard end > start else { continue }
            let output = whisper.generate(
                audio: MLXArray(Array(samples[start..<end])),
                generationParameters: parameters
            )
            let regionText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !regionText.isEmpty {
                let recognitionStart = Double(start) / 16_000
                let recognitionEnd = Double(end) / 16_000
                let outputSpans = Self.recognizedSpans(
                    from: output.segments,
                    fallbackText: regionText,
                    recognitionStart: recognitionStart,
                    recognitionEnd: recognitionEnd,
                    ownershipStart: chunk.ownershipStart,
                    ownershipEnd: chunk.ownershipEnd,
                    audioDuration: Double(samples.count) / 16_000
                )
                recognizedSpans.append(contentsOf: outputSpans)
            }
            if whisperLanguage == nil { whisperLanguage = output.language }
            progressUpdate(.init(
                stage: .recognizing,
                fraction: 0.20 + 0.30 * Double(index + 1) / Double(recognitionChunks.count),
                completed: index + 1,
                total: recognitionChunks.count,
                message: "Recognizing speech chunk \(index + 1) of \(recognitionChunks.count)…"
            ))
        }
        let quality = TranscriptionQualityProcessor.preprocess(
            spans: recognizedSpans,
            languageCode: recognitionLanguageCode
        )
        recognizedSpans = quality.spans
        let text = recognizedSpans.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { throw LocalAIError.emptyTranscript }
        let inferredLanguage = TranscriptionLanguage(
            code: whisperLanguage ?? Self.detectLanguageCode(in: text)
        )
        let resolvedLanguageCode = outputLanguageCode ?? inferredLanguage.outputLanguageCode

        let alignmentSpans = try LongFormAlignmentEngine.alignmentChunks(from: recognizedSpans)
        progressUpdate(.init(
            stage: .aligning,
            fraction: 0.52,
            completed: 0,
            total: alignmentSpans.count,
            message: "Aligning words to the waveform…"
        ))
        let aligner = try await alignerModel()
        let language = Self.alignerLanguage(from: resolvedLanguageCode)
        let alignmentSpanCount = alignmentSpans.count
        let alignment = try LongFormAlignmentEngine.alignDetailed(
            audio: samples,
            sampleRate: 16_000,
            spans: recognizedSpans,
            language: language,
            aligner: aligner,
            progress: { fraction, message in
                progressUpdate(.init(
                    stage: .aligning,
                    fraction: 0.52 + 0.18 * fraction,
                    completed: min(alignmentSpanCount, Int((fraction * Double(alignmentSpanCount)).rounded())),
                    total: alignmentSpanCount,
                    message: message
                ))
            }
        )
        let aligned = alignment.words

        Memory.clearCache()
        let speechRanges = speechRegions.map {
            SpeechTimeRange(start: Double($0.startTime), end: Double($0.endTime))
        }
        let timeline: SpeakerActivityTimeline
        if speakerCount == 1 {
            progressUpdate(.init(stage: .assigningSpeakers, fraction: 0.88, message: "Assigning the single speaker locally…"))
            timeline = SpeakerActivityPostprocessor.singleSpeaker(
                speechRanges: speechRanges,
                audioDuration: Double(samples.count) / 16_000
            )
        } else {
            progressUpdate(.init(stage: .diarizing, fraction: 0.72, message: "Loading streaming speaker model…"))
            let diarizer = try streamingDiarizationModel()
            timeline = try await diarizer.diarize(
                audio: samples,
                sampleRate: 16_000,
                speechRanges: speechRanges,
                policy: .standard(requestedSpeakerCount: speakerCount),
                progress: { update in
                    progressUpdate(.init(
                        stage: .diarizing,
                        fraction: 0.72 + update.fraction * 0.24,
                        completed: update.completed,
                        total: update.total,
                        message: update.message
                    ))
                }
            )
            try Task.checkCancellation()
        }
        let words = TranscriptionQualityProcessor.postprocess(
            Self.assignSpeakers(
            to: aligned,
            timeline: timeline,
            audioDuration: Double(samples.count) / 16_000
            ),
            chineseScript: TranscriptionLanguage(code: resolvedLanguageCode).chineseScript
        )
        let segments = Self.makeSegments(from: words)
        progressUpdate(.init(stage: .finalizing, fraction: 0.99, message: "Finalizing transcript…"))
        var diagnostics = timeline.diagnostics
        if alignment.coarseTimedUnitCount > 0 {
            diagnostics = diagnostics.addingWarning(
                "\(alignment.coarseTimedUnitCount) word timings are estimates from ASR segment boundaries because forced alignment was unstable."
            )
        }
        if let warning = quality.statistics.warning {
            diagnostics = diagnostics.addingWarning(warning)
        }
        return LocalTranscriptionOutput(
            result: TranscriptionResult(
                text: TranscriptSegmenter.joinedText(words.map(\.text)),
                language: resolvedLanguageCode,
                words: words,
                segments: segments
            ),
            diarizationDiagnostics: diagnostics
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
        var requiredModels: [LocalModelID] = [.forcedAligner]
        if case .diarize(let requestedSpeakerCount) = request.speakerAttribution,
           requestedSpeakerCount != 1 {
            requiredModels.append(contentsOf: [.sileroVAD, .sortformerDiarization])
        }
        try Self.requireModels(requiredModels)
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }

        progressUpdate(.init(stage: .decoding, fraction: 0.04, message: "Decoding audio for script alignment…"))
        let preparedURL: URL
        let shouldRemovePrepared: Bool
        if ClipType(fileExtension: sourceURL.pathExtension.lowercased()) == .video {
            preparedURL = try await Transcription.extractAudioTrack(from: sourceURL)
            shouldRemovePrepared = true
        } else {
            preparedURL = sourceURL
            shouldRemovePrepared = false
        }
        defer { if shouldRemovePrepared { try? FileManager.default.removeItem(at: preparedURL) } }
        let samples = try AudioFileLoader.load(url: preparedURL, targetSampleRate: 16_000)
        guard !samples.isEmpty else { throw LocalAIError.noAudioOutput }
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
            progress: { fraction, message in
                progressUpdate(.init(
                    stage: .aligning,
                    fraction: 0.12 + fraction * 0.68,
                    message: message
                ))
            }
        )
        progressUpdate(.init(stage: .assigningSpeakers, fraction: 0.84, message: "Assigning script speakers…"))
        let untitledWords = Self.assignSpeakers(
            to: aligned.words,
            turns: [],
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
                    TranscriptionWord(text: $0.text, start: $0.start, end: $0.end, speaker: "Speaker 1")
                }
            } else {
                Memory.clearCache()
                let vad = try await vadModel()
                let speechRegions = vad.detectSpeech(audio: samples, sampleRate: 16_000)
                let speechRanges = speechRegions.map {
                    SpeechTimeRange(start: Double($0.startTime), end: Double($0.endTime))
                }
                let diarizer = try streamingDiarizationModel()
                let timeline = try await diarizer.diarize(
                    audio: samples,
                    sampleRate: 16_000,
                    speechRanges: speechRanges,
                    policy: .standard(requestedSpeakerCount: requestedSpeakerCount),
                    progress: { _ in }
                )
                words = Self.assignSpeakers(
                    to: aligned.words,
                    timeline: timeline,
                    audioDuration: audioDuration
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
    private func whisperModel(id: LocalModelID) async throws -> WhisperModel {
        if let whisper, whisper.id == id { return whisper.model }
        whisper = nil
        Memory.clearCache()
        let directory = try LocalModelManager.directory(for: id)
        let loaded = try await WhisperModel.fromDirectory(directory)
        whisper = (id, loaded)
        return loaded
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

    private func vadModel() async throws -> SileroVADModel {
        if let vad { return vad }
        let loaded = try await SileroVADModel.fromPretrained(
            modelId: SileroVADModel.defaultModelId,
            engine: .mlx,
            cacheDir: LocalModelManager.directory(for: .sileroVAD),
            offlineMode: true
        )
        vad = loaded
        return loaded
    }

    private func streamingDiarizationModel() throws -> MLXStreamingSortformerEngine {
        if let streamingDiarizer { return streamingDiarizer }
        let descriptor = LocalModelManager.catalog.first { $0.id == .sortformerDiarization }!
        let loaded = try MLXStreamingSortformerEngine(
            modelDirectory: LocalModelManager.directory(for: .sortformerDiarization),
            modelRevision: descriptor.revision
        )
        streamingDiarizer = loaded
        return loaded
    }

    private func diarizationModel() async throws -> PyannoteDiarizationPipeline {
        if let diarizer { return diarizer }
        let loaded = try await PyannoteDiarizationPipeline.fromPretrained(
            useVADFilter: true,
            offlineMode: true
        )
        diarizer = loaded
        return loaded
    }

    private nonisolated static func requireModels(_ ids: [LocalModelID]) throws {
        let missing = ids.compactMap { id -> String? in
            guard let model = LocalModelManager.catalog.first(where: { $0.id == id }) else { return id.rawValue }
            return LocalModelManager.isInstalled(model) ? nil : model.title
        }
        if !missing.isEmpty { throw LocalAIError.missingModels(missing.joined(separator: ", ")) }
    }

    private nonisolated static func recognizedSpans(
        from segments: [[String: Any]]?,
        fallbackText: String,
        recognitionStart: Double,
        recognitionEnd: Double,
        ownershipStart: Double,
        ownershipEnd: Double,
        audioDuration: Double
    ) -> [RecognizedSpan] {
        let parsed = (segments ?? []).compactMap { segment -> RecognizedSpan? in
            guard let text = segment["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let localStart = numericValue(segment["start"]),
                  let localEnd = numericValue(segment["end"]) else { return nil }
            let absoluteStart = min(audioDuration, max(0, recognitionStart + localStart))
            let absoluteEnd = min(audioDuration, max(absoluteStart, recognitionStart + localEnd))
            let midpoint = absoluteStart + (absoluteEnd - absoluteStart) / 2
            guard midpoint >= ownershipStart, midpoint < ownershipEnd else { return nil }
            let start = max(ownershipStart, absoluteStart)
            let end = min(ownershipEnd, absoluteEnd)
            guard end > start else { return nil }
            return RecognizedSpan(text: trimmed, startTime: start, endTime: end)
        }
        if !parsed.isEmpty { return parsed }
        let start = min(audioDuration, max(0, ownershipStart))
        let end = min(audioDuration, max(start, min(ownershipEnd, recognitionEnd)))
        guard end > start else { return [] }
        return [RecognizedSpan(text: fallbackText, startTime: start, endTime: end)]
    }

    private nonisolated static func languageDetectionSamples(
        from samples: [Float],
        speechRegions: [SpeechSegment]
    ) -> [Float] {
        let maximumSamples = 30 * 16_000
        var selected: [Float] = []
        selected.reserveCapacity(min(samples.count, maximumSamples))

        for region in speechRegions where selected.count < maximumSamples {
            let start = min(samples.count, max(0, Int((region.startTime * 16_000).rounded(.down))))
            let end = min(samples.count, max(start, Int((region.endTime * 16_000).rounded(.up))))
            guard end > start else { continue }
            let remaining = maximumSamples - selected.count
            selected.append(contentsOf: samples[start..<min(end, start + remaining)])
        }
        return selected.isEmpty ? samples : selected
    }

    private nonisolated static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Float: Double(value)
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
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

    private nonisolated static func diarizationConfig(for requestedCount: Int?) -> DiarizationConfig {
        // The upstream clustering loop merges while cosine distance is BELOW the
        // threshold (despite an inverted comment in DiarizationConfig). For an
        // explicit count, deliberately over-cluster first so the deterministic
        // centroid merge below can reach that count instead of getting stuck below it.
        let threshold: Float = switch requestedCount {
        case 1: 2.0
        case .some(let count) where (2...4).contains(count): 0.45
        default: 0.715
        }
        return DiarizationConfig(clusteringThreshold: threshold)
    }

    nonisolated static func constrainSpeakers(
        _ turns: [DiarizedSegment],
        centroids: [[Float]],
        requestedCount: Int?
    ) -> [DiarizedSegment] {
        guard let requestedCount, requestedCount > 0, !turns.isEmpty else { return turns }
        if requestedCount == 1 {
            return turns.map { DiarizedSegment(startTime: $0.startTime, endTime: $0.endTime, speakerId: 0) }
        }
        let ids = Array(Set(turns.map(\.speakerId))).sorted()
        guard ids.count > requestedCount else { return turns }
        let durationByID = Dictionary(grouping: turns, by: \.speakerId).mapValues { items in
            items.reduce(Float(0)) { $0 + max(0, $1.endTime - $1.startTime) }
        }

        func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
            guard a.count == b.count, !a.isEmpty else { return 2 }
            var dot: Float = 0, aa: Float = 0, bb: Float = 0
            for index in a.indices {
                dot += a[index] * b[index]
                aa += a[index] * a[index]
                bb += b[index] * b[index]
            }
            let denominator = (aa * bb).squareRoot()
            return denominator > 0 ? 1 - dot / denominator : 2
        }

        func centroid(of group: [Int]) -> [Float]? {
            let available = group.filter { centroids.indices.contains($0) && !centroids[$0].isEmpty }
            guard let first = available.first else { return nil }
            var result = [Float](repeating: 0, count: centroids[first].count)
            var totalWeight: Float = 0
            for id in available where centroids[id].count == result.count {
                let weight = max(durationByID[id] ?? 0, 0.001)
                for index in result.indices { result[index] += centroids[id][index] * weight }
                totalWeight += weight
            }
            guard totalWeight > 0 else { return nil }
            return result.map { $0 / totalWeight }
        }

        var groups = ids.map { [$0] }
        while groups.count > requestedCount {
            var best: (left: Int, right: Int, distance: Float)?
            for left in groups.indices {
                for right in groups.indices where right > left {
                    let distance: Float
                    if let a = centroid(of: groups[left]), let b = centroid(of: groups[right]) {
                        distance = cosineDistance(a, b)
                    } else {
                        distance = Float(abs((groups[left].first ?? 0) - (groups[right].first ?? 0)))
                    }
                    if best == nil || distance < best!.distance {
                        best = (left, right, distance)
                    }
                }
            }
            guard let best else { break }
            groups[best.left].append(contentsOf: groups[best.right])
            groups.remove(at: best.right)
        }

        let compact = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { groupIndex, members in
            members.map { ($0, groupIndex) }
        })
        return turns.map {
            DiarizedSegment(
                startTime: $0.startTime,
                endTime: $0.endTime,
                speakerId: compact[$0.speakerId] ?? 0
            )
        }
    }

    nonisolated static func assignSpeakers(
        to aligned: [AlignedWord],
        timeline: SpeakerActivityTimeline,
        audioDuration: Double
    ) -> [TranscriptionWord] {
        var previousStart = 0.0
        return aligned.map { word in
            let timing = normalizedWordTiming(
                start: Double(word.startTime),
                end: Double(word.endTime),
                previousStart: previousStart,
                audioDuration: audioDuration
            )
            previousStart = timing.start
            let speakerID = timeline.speakerForWord(start: timing.start, end: timing.end)
            return TranscriptionWord(
                text: word.text,
                start: timing.start,
                end: timing.end,
                speaker: speakerID.map { "Speaker \($0 + 1)" }
            )
        }
    }

    nonisolated static func assignSpeakers(
        to aligned: [AlignedWord],
        turns: [DiarizedSegment],
        audioDuration: Double
    ) -> [TranscriptionWord] {
        var previousStart = 0.0
        return aligned.map { word in
            let timing = normalizedWordTiming(
                start: Double(word.startTime),
                end: Double(word.endTime),
                previousStart: previousStart,
                audioDuration: audioDuration
            )
            let start = timing.start
            let end = timing.end
            previousStart = start
            var overlapBySpeaker: [Int: Double] = [:]
            for turn in turns {
                let overlap = min(end, Double(turn.endTime)) - max(start, Double(turn.startTime))
                if overlap > 0 { overlapBySpeaker[turn.speakerId, default: 0] += overlap }
            }
            let speakerID = overlapBySpeaker.max { $0.value < $1.value }?.key
                ?? turns.min { lhs, rhs in
                    abs((Double(lhs.startTime + lhs.endTime) / 2) - ((start + end) / 2))
                        < abs((Double(rhs.startTime + rhs.endTime) / 2) - ((start + end) / 2))
                }?.speakerId
            return TranscriptionWord(
                text: word.text,
                start: start,
                end: end,
                speaker: speakerID.map { "Speaker \($0 + 1)" }
            )
        }
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
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Voxella Studio/MLXAudioTTS", isDirectory: true)
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
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio/Dubs", isDirectory: true)
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
