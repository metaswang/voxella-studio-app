import Foundation

protocol MediaJobEventSource: Sendable {
    func events(for request: MediaFlowRequest) -> AsyncStream<MediaJobEvent>
}

actor MediaFlowExecutor: MediaJobEventSource {
    static let shared = MediaFlowExecutor()

    typealias LLMClientFactory = @Sendable () async throws -> any LLMTextClient

    private let llmClientFactory: LLMClientFactory?

    init(llmClientFactory: LLMClientFactory? = nil) {
        self.llmClientFactory = llmClientFactory
    }

    private struct FlowContext {
        var mediaURL: URL?
        var script: String?
        var alignmentSpans: [KnownTextAlignmentSpan] = []
        var transcript: TranscriptionResult?
        var diagnostics: DiarizationDiagnostics?
        var subtitles: SubtitleTrack?
        var translation: SubtitleTrack?
        var dub: DubFlowResult?
        var warnings: [String] = []

        init(input: MediaFlowInput) {
            switch input {
            case .media(let URL):
                mediaURL = URL
            case .knownTextAudio(let media, let script, let spans):
                mediaURL = media
                self.script = script
                alignmentSpans = spans
            case .transcript(let transcript, let subtitles, let translation):
                self.transcript = transcript
                self.subtitles = subtitles
                self.translation = translation
            case .script(let script):
                self.script = script
            }
        }
    }

    nonisolated func events(for request: MediaFlowRequest) -> AsyncStream<MediaJobEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.execute(request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ request: MediaFlowRequest,
        continuation: AsyncStream<MediaJobEvent>.Continuation
    ) async {
        guard !request.steps.isEmpty else {
            yieldTerminal(
                requestID: request.id,
                status: .failed,
                message: MediaFlowError.emptyFlow.localizedDescription,
                continuation: continuation
            )
            continuation.finish()
            return
        }

        let totalWeight = request.steps.reduce(0) { $0 + $1.defaultWeight }
        var completedWeight = 0.0
        var context = FlowContext(input: request.input)
        var LLMClients: [LLMUseCase: any LLMTextClient] = [:]

        continuation.yield(.progress(MediaJobProgressEvent(
            jobID: request.id,
            stage: .flow,
            status: .started,
            step: "flow_started",
            progress: 0,
            stageProgress: 0,
            message: "Media flow started"
        )))

        do {
            for step in request.steps {
                try Task.checkCancellation()
                let stepWeight = step.defaultWeight
                let completedBeforeStep = completedWeight
                let progressEvent: @Sendable (
                    MediaFlowStage,
                    String,
                    Double,
                    Int?,
                    Int?,
                    String
                ) -> Void = { stage, stepName, fraction, current, total, message in
                    let overall = (completedBeforeStep + stepWeight * fraction) / totalWeight
                    continuation.yield(.progress(MediaJobProgressEvent(
                        jobID: request.id,
                        stage: stage,
                        status: .processing,
                        step: stepName,
                        progress: overall,
                        stageProgress: fraction,
                        current: current,
                        total: total,
                        message: message
                    )))
                }

                switch step {
                case .transcribe(let payload):
                    guard let mediaURL = context.mediaURL else {
                        throw MediaFlowError.missingMedia
                    }
                    let output = try await LocalSpeechPipeline.shared.transcribeDetailed(
                        sourceURL: mediaURL,
                        languageCode: payload.languageCode,
                        speakerCount: payload.speakerCount,
                        clipRangeSeconds: payload.clipRangeSeconds,
                        progressUpdate: { update in
                            progressEvent(
                                .transcription,
                                update.stage.rawValue,
                                update.fraction,
                                update.completed,
                                update.total,
                                update.message
                            )
                        }
                    )
                    let transcript = payload.clipRangeSeconds.map {
                        output.result.offsetting(by: $0.lowerBound)
                    } ?? output.result
                    context.transcript = transcript
                    context.diagnostics = output.diarizationDiagnostics
                    continuation.yield(.artifact(.transcription(
                        transcript,
                        output.diarizationDiagnostics,
                        output.alignmentDiagnostics
                    )))

                case .alignScript(let payload):
                    guard let mediaURL = context.mediaURL else {
                        throw MediaFlowError.missingMedia
                    }
                    let text = payload.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfEmpty
                        ?? context.script?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .nilIfEmpty
                    guard let text else { throw MediaFlowError.missingTranscript }
                    let speakerAttribution: KnownTextSpeakerAttribution
                    switch payload.speakerMode {
                    case .providedSegments:
                        speakerAttribution = context.alignmentSpans.isEmpty ? .none : .providedSpans
                    case .diarize(let requestedSpeakerCount):
                        speakerAttribution = .diarize(requestedSpeakerCount: requestedSpeakerCount)
                    case .none:
                        speakerAttribution = .none
                    }
                    let output = try await LocalSpeechPipeline.shared.alignKnownText(
                        sourceURL: mediaURL,
                        request: KnownTextAlignmentRequest(
                            text: text,
                            languageCode: payload.languageCode,
                            spans: context.alignmentSpans,
                            anchor: context.alignmentSpans.isEmpty ? context.transcript : nil,
                            speakerAttribution: speakerAttribution
                        ),
                        progressUpdate: { update in
                            progressEvent(
                                .alignment,
                                "alignment_\(update.stage.rawValue)",
                                update.fraction,
                                update.completed,
                                update.total,
                                update.message
                            )
                        }
                    )
                    context.transcript = output.result
                    let track = SubtitleTrack.fromDubSegments(
                        context.dub?.segments ?? [],
                        language: output.result.language
                    ) ?? SubtitleTrack.fromTranscript(output.result)
                    context.subtitles = track
                    continuation.yield(.artifact(.alignment(output)))
                    continuation.yield(.artifact(.subtitles(track, rebuiltSegments: nil)))

                case .prepareSubtitles(let payload):
                    guard let transcript = context.transcript else {
                        throw MediaFlowError.missingTranscript
                    }
                    if LLMClients[.subtitleProcessing] == nil {
                        do {
                            LLMClients[.subtitleProcessing] = try await makeLLMClient(
                                for: .subtitleProcessing
                            )
                        } catch {
                            try Task.checkCancellation()
                            try applyPreparedSubtitleFallback(
                                transcript: transcript,
                                payload: payload,
                                reason: error.localizedDescription,
                                orThrow: error,
                                context: &context,
                                progressEvent: progressEvent,
                                continuation: continuation
                            )
                            break
                        }
                    }
                    guard let client = LLMClients[.subtitleProcessing] else {
                        throw LLMConfigurationError.noConfiguredModel(.subtitleProcessing)
                    }
                    let pipeline = SubtitlePostprocessPipeline(client: client)
                    let output: SubtitlePostprocessResult
                    do {
                        output = try await pipeline.process(
                            transcript: transcript,
                            options: payload,
                            progress: { fraction, current, total, message in
                                progressEvent(
                                    .subtitlePreparation,
                                    "subtitle_preparation",
                                    fraction,
                                    current,
                                    total,
                                    message
                                )
                            }
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        if case LLMClientError.insufficientCredits = error {
                            throw error
                        }
                        try applyPreparedSubtitleFallback(
                            transcript: transcript,
                            payload: payload,
                            reason: error.localizedDescription,
                            orThrow: error,
                            context: &context,
                            progressEvent: progressEvent,
                            continuation: continuation
                        )
                        break
                    }
                    let track = output.track
                    let rebuiltSegments = output.rebuiltSegments
                    context.transcript = TranscriptionResult(
                        text: TranscriptSegmenter.joinedText(
                            output.rebuiltSegments.map(\.text),
                            language: transcript.language
                        ),
                        language: transcript.language,
                        words: transcript.words,
                        segments: output.rebuiltSegments,
                        asrEngine: transcript.asrEngine
                    )
                    context.warnings.append(contentsOf: output.warnings)
                    context.subtitles = track
                    continuation.yield(
                        .artifact(.subtitles(track, rebuiltSegments: rebuiltSegments))
                    )

                case .translate(let payload):
                    let sourceTrack: SubtitleTrack
                    if let subtitles = context.subtitles {
                        sourceTrack = subtitles
                    } else if let transcript = context.transcript {
                        sourceTrack = SubtitleTrack.fromTranscript(transcript)
                    } else {
                        throw MediaFlowError.missingTranscript
                    }
                    if LLMClients[.translation] == nil {
                        LLMClients[.translation] = try await makeLLMClient(for: .translation)
                    }
                    guard let client = LLMClients[.translation] else {
                        throw LLMConfigurationError.noConfiguredModel(.translation)
                    }
                    let processor = TranslationLLMProcessor(client: client)
                    let track = try await processor.translate(
                        track: sourceTrack,
                        options: payload,
                        progress: { fraction, current, total, message in
                            progressEvent(
                                .translation,
                                "translation",
                                fraction,
                                current,
                                total,
                                message
                            )
                        }
                    )
                    context.translation = track
                    continuation.yield(.artifact(.translation(track)))

                case .dub(var payload):
                    if payload.segments.isEmpty {
                        payload.segments = try dubSegments(from: context)
                    }
                    let result = try await LocalDubFlowRenderer.shared.render(
                        payload: payload,
                        progress: { update in
                            progressEvent(
                                update.stage,
                                update.stage.rawValue,
                                update.fraction,
                                update.current,
                                update.total,
                                update.message
                            )
                        }
                    )
                    context.dub = result
                    context.mediaURL = result.outputURL
                    let timelineSegments = result.segments.sorted { lhs, rhs in
                        lhs.start == rhs.start ? lhs.index < rhs.index : lhs.start < rhs.start
                    }
                    context.script = timelineSegments
                        .map(\.text)
                        .joined(separator: " ")
                    context.alignmentSpans = timelineSegments.map {
                        KnownTextAlignmentSpan(
                            text: $0.text,
                            start: $0.start,
                            end: $0.end,
                            speaker: $0.speaker
                        )
                    }
                    continuation.yield(.artifact(.dub(result)))
                }

                completedWeight += stepWeight
                continuation.yield(.progress(MediaJobProgressEvent(
                    jobID: request.id,
                    stage: step.stage,
                    status: .processing,
                    step: "\(step.stage.rawValue)_completed",
                    progress: completedWeight / totalWeight,
                    stageProgress: 1,
                    message: "\(step.stage.title) completed"
                )))
            }

            let completionMessage = context.warnings.isEmpty
                ? "Media flow completed"
                : "Completed with warning: \(context.warnings.joined(separator: " "))"
            yieldTerminal(
                requestID: request.id,
                status: .completed,
                message: completionMessage,
                continuation: continuation
            )
        } catch is CancellationError {
            yieldTerminal(
                requestID: request.id,
                status: .cancelled,
                message: "Media flow cancelled",
                continuation: continuation
            )
        } catch {
            yieldTerminal(
                requestID: request.id,
                status: .failed,
                message: error.localizedDescription,
                continuation: continuation
            )
        }
        continuation.finish()
    }

    private func makeLLMClient(for useCase: LLMUseCase) async throws -> any LLMTextClient {
        if let llmClientFactory {
            return try await llmClientFactory()
        }
        return try await AITransportPolicy.makeTextClient(for: useCase)
    }

    private func applyPreparedSubtitleFallback(
        transcript: TranscriptionResult,
        payload: SubtitleProcessingPayload,
        reason: String,
        orThrow error: Error,
        context: inout FlowContext,
        progressEvent: @Sendable (
            MediaFlowStage,
            String,
            Double,
            Int?,
            Int?,
            String
        ) -> Void,
        continuation: AsyncStream<MediaJobEvent>.Continuation
    ) throws {
        let ruleBasedFallback = SubtitlePostprocessPipeline.ruleBasedFallback(
            from: transcript,
            options: payload
        )
        let fallbackSubtitleTrack = ruleBasedFallback?.track
            ?? SubtitleTrack.fromTranscript(transcript)
        guard !fallbackSubtitleTrack.cues.isEmpty else { throw error }
        applySubtitleFallback(
            track: fallbackSubtitleTrack,
            rebuiltSegments: ruleBasedFallback?.rebuiltSegments,
            transcript: transcript,
            reason: reason,
            usedRuleBasedSegmentation: ruleBasedFallback != nil,
            context: &context,
            progressEvent: progressEvent,
            continuation: continuation
        )
    }

    private func applySubtitleFallback(
        track: SubtitleTrack,
        rebuiltSegments: [TranscriptionSegment]?,
        transcript: TranscriptionResult,
        reason: String,
        usedRuleBasedSegmentation: Bool,
        context: inout FlowContext,
        progressEvent: @Sendable (
            MediaFlowStage,
            String,
            Double,
            Int?,
            Int?,
            String
        ) -> Void,
        continuation: AsyncStream<MediaJobEvent>.Continuation
    ) {
        Log.transcription.warning("subtitle cleanup fallback: \(reason)")
        let warning = usedRuleBasedSegmentation
            ? "Subtitle cleanup failed; segmented with rule-based fallback timings: \(reason)"
            : "Subtitle cleanup failed; using transcript timings: \(reason)"
        context.warnings.append(warning)
        if let rebuiltSegments, !rebuiltSegments.isEmpty {
            context.transcript = TranscriptionResult(
                text: TranscriptSegmenter.joinedText(
                    rebuiltSegments.map(\.text),
                    language: transcript.language
                ),
                language: transcript.language,
                words: transcript.words,
                segments: rebuiltSegments,
                asrEngine: transcript.asrEngine
            )
        }
        context.subtitles = track
        let progressMessage = usedRuleBasedSegmentation
            ? "Subtitle cleanup failed; segmented with rule-based fallback timings"
            : "Subtitle cleanup failed; using transcript timings"
        progressEvent(
            .subtitlePreparation,
            "subtitle_preparation_fallback",
            1,
            nil,
            nil,
            progressMessage
        )
        continuation.yield(.artifact(.subtitles(track, rebuiltSegments: rebuiltSegments)))
    }

    private func dubSegments(from context: FlowContext) throws -> [DubSegmentPayload] {
        if let track = context.translation ?? context.subtitles {
            return track.cues.map {
                DubSegmentPayload(
                    index: $0.id,
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speaker: $0.speaker,
                    sourceSubtitleID: $0.sourceIDs.first
                )
            }
        }
        if let transcript = context.transcript {
            return SubtitleTrack.fromTranscript(transcript).cues.map {
                DubSegmentPayload(
                    index: $0.id,
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speaker: $0.speaker,
                    sourceSubtitleID: $0.sourceIDs.first
                )
            }
        }
        if let script = context.script?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            return [DubSegmentPayload(index: 0, text: script)]
        }
        throw MediaFlowError.emptyDubScript
    }

    private func yieldTerminal(
        requestID: UUID,
        status: MediaJobStatus,
        message: String,
        continuation: AsyncStream<MediaJobEvent>.Continuation
    ) {
        continuation.yield(.progress(MediaJobProgressEvent(
            jobID: requestID,
            stage: .flow,
            status: status,
            step: "flow_\(status.rawValue)",
            progress: status == .completed ? 1 : 0,
            stageProgress: status == .completed ? 1 : 0,
            message: message
        )))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
