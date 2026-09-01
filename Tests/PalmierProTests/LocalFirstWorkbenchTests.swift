import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

#if BUNDLED_SPEECH
import AudioCommon
#endif

@Suite("Voxella local-first workbench")
struct LocalFirstWorkbenchTests {
    @Test func voiceReferencePreparationPreservesDurationAndLeadingSilence() async throws {
        let sourceURL = FileIO.temporaryFileURL(pathExtension: "wav")
        let duration = 12.25
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try #require(buffer.floatChannelData?[0])
        let voicedStart = Int(sampleRate * 1.2)
        for index in 0..<Int(frameCount) {
            channel[index] = index < voicedStart
                ? 0
                : 0.15 * sin(2 * .pi * 220 * Float(index - voicedStart) / Float(sampleRate))
        }
        do {
            let source = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try source.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try await VoiceReferenceProcessor.shared.prepare(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: prepared.URL) }

        #expect(abs(prepared.duration - duration) < 0.02)
        #expect(prepared.duration > 10)

        let output = try AVAudioFile(forReading: prepared.URL)
        #expect(output.processingFormat.sampleRate == 24_000)
        #expect(output.processingFormat.channelCount == 1)
        #expect(output.fileFormat.commonFormat == .pcmFormatInt16)
        let leadingFrameCount = AVAudioFrameCount(output.processingFormat.sampleRate * 0.5)
        let leading = try #require(AVAudioPCMBuffer(
            pcmFormat: output.processingFormat,
            frameCapacity: leadingFrameCount
        ))
        try output.read(into: leading, frameCount: leadingFrameCount)
        let leadingChannel = try #require(leading.floatChannelData?[0])
        let leadingPeak = (0..<Int(leading.frameLength)).reduce(Float.zero) {
            max($0, abs(leadingChannel[$1]))
        }
        #expect(leadingPeak < 0.000_1)
    }

    @Test func exposesOnlyFirstReleaseRoutes() {
        #expect(
            WorkbenchRoute.allCases
                == [.recent, .dashboard, .transcribe, .meetBot, .dub, .voiceLibrary, .videoEditor, .session]
        )
        #expect(Project.fileExtension == "voxella")
        #expect(Project.legacyFileExtension == "palmier")
    }

    @Test func modelCatalogIsPinnedAndFitsM5InstallBudget() {
        let catalog = LocalModelManager.catalog
        #expect(catalog.count == 11)
        #expect(Set(catalog.map(\.repository)).count == catalog.count)
        #expect(catalog.allSatisfy { $0.revision.count == 40 })
        #expect(catalog.allSatisfy {
            if case .coreMLBundle = $0.storage { return true }
            return $0.weightSHA256.count == 64 && $0.weightByteSize > 0
        })
        #expect(catalog.allSatisfy { $0.byteSize > 0 })
        #expect(catalog.flatMap(\.requiredArtifacts).allSatisfy { $0.byteSize > 0 && $0.sha256.count == 64 })
        #expect(catalog.filter(\.isRecommended).count == 9)
        #expect(catalog.allSatisfy { !$0.isLegacy })

        let coreMLVAD = catalog.first { $0.id == .sileroVAD }!
        #expect(coreMLVAD.weightByteSize == 0)
        #expect(coreMLVAD.weightSHA256.isEmpty)
        #expect(coreMLVAD.storage == .coreMLBundle(directoryName: LocalSpeechVAD.coreMLBundleName))
        #expect(coreMLVAD.repository == "FluidInference/silero-vad-coreml")
        #expect(LocalSpeechVAD.requiredBundleFiles.allSatisfy { !$0.contains("*") })
        #expect(LocalSpeechVAD.requiredBundleFiles.contains("weights/weight.bin"))

        let qwenASR = catalog.first { $0.id == .qwen3ASR17B8Bit }!
        let parakeetASR = catalog.first { $0.id == .parakeetTDT06Bv3 }!
        let recommendedASR = catalog.first { $0.id == .whisperLargeV3Turbo8Bit }!
        let qualityASR = catalog.first { $0.id == .whisperLargeV3TurboFP16 }!
        #expect(LocalModelManager.defaultASRModelID == .whisperLargeV3Turbo8Bit)
        #expect(qwenASR.isRecommended)
        #expect(parakeetASR.isRecommended)
        #expect(recommendedASR.isRecommended)
        #expect(!qualityASR.isRecommended)
        #expect(recommendedASR.asrSpecification?.precision == .eightBit)
        #expect(qualityASR.asrSpecification?.precision == .fp16)
        #expect(recommendedASR.asrSpecification?.decoderLayers == 4)
        #expect(qualityASR.asrSpecification?.decoderLayers == 4)
        #expect(recommendedASR.requiredArtifacts.contains { $0.filename == "tokenizer.json" })
        #expect(qualityASR.requiredArtifacts.contains { $0.filename == "tokenizer.json" })
        #expect(catalog.first { $0.id == .forcedAligner }?.requiredFor == [.transcribe, .dub])
        let weMM = catalog.first { $0.id == .weMMEmbedding2B4Bit }!
        #expect(weMM.repository == "hfadam/WeMM-Embedding-2B-MLX-4bit")
        #expect(weMM.requiredFor == [.search])
        #expect(weMM.requiredArtifacts.contains { $0.filename == "embedding_chat_template.jinja" })

        let sharedCodecBytes: Int64 = 682_300_739
        let recommendedInstallBytes = catalog.filter(\.isRecommended)
            .reduce(Int64(0)) { $0 + $1.byteSize } + sharedCodecBytes
        let fullInstallBytes = catalog.reduce(Int64(0)) { $0 + $1.byteSize } + sharedCodecBytes
        #expect(recommendedInstallBytes < 12_000_000_000)
        #expect(fullInstallBytes < 15_000_000_000)
    }

    @Test func largeTurboConfigurationsRejectMislabeledPrecisionOrArchitecture() throws {
        let eightBit = LocalModelManager.catalog.first { $0.id == .whisperLargeV3Turbo8Bit }!
        let fp16 = LocalModelManager.catalog.first { $0.id == .whisperLargeV3TurboFP16 }!
        let eightBitJSON = Data(
            #"{"vocab_size":51866,"num_mel_bins":128,"encoder_layers":32,"decoder_layers":4,"quantization":{"group_size":64,"bits":8}}"#.utf8
        )
        let fp16JSON = Data(
            #"{"vocab_size":51866,"num_mel_bins":128,"encoder_layers":32,"decoder_layers":4}"#.utf8
        )
        let wrongArchitectureJSON = Data(
            #"{"vocab_size":51866,"num_mel_bins":128,"encoder_layers":32,"decoder_layers":8,"quantization":{"group_size":64,"bits":8}}"#.utf8
        )

        #expect(LocalModelManager.validateASRConfiguration(eightBitJSON, specification: eightBit.asrSpecification!))
        #expect(LocalModelManager.validateASRConfiguration(fp16JSON, specification: fp16.asrSpecification!))
        #expect(!LocalModelManager.validateASRConfiguration(fp16JSON, specification: eightBit.asrSpecification!))
        #expect(!LocalModelManager.validateASRConfiguration(eightBitJSON, specification: fp16.asrSpecification!))
        #expect(!LocalModelManager.validateASRConfiguration(wrongArchitectureJSON, specification: eightBit.asrSpecification!))
    }

    @Test func asrChunkPlannerBoundsLongAudioAndOwnsEverySpeechIntervalOnce() {
        let chunks = ASRChunkPlanner.chunks(
            speechRanges: [
                .init(start: 0.2, end: 8),
                .init(start: 8.4, end: 16),
                .init(start: 20, end: 81),
                .init(start: 89.5, end: 95),
            ],
            audioDuration: 95,
            configuration: .init(
                maximumWindowDuration: 28,
                boundaryContextDuration: 0.75,
                maximumMergeGap: 0.75
            )
        )

        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.ownershipEnd > $0.ownershipStart })
        #expect(chunks.allSatisfy { $0.inputStart >= 0 && $0.inputEnd <= 95 })
        #expect(chunks.allSatisfy { $0.inputDuration <= 29.5 + 0.000_001 })
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { pair in
            pair.0.ownershipEnd <= pair.1.ownershipStart
        })
        #expect(chunks.first?.ownershipStart == 0.2)
        #expect(chunks.last?.ownershipEnd == 95)
    }

    @Test func asrChunkPlannerNormalizesInputAndRejectsInvalidConfiguration() {
        let chunks = ASRChunkPlanner.chunks(
            speechRanges: [
                .init(start: 7, end: 9),
                .init(start: -2, end: 2),
                .init(start: .nan, end: 4),
                .init(start: 12, end: 11),
            ],
            audioDuration: 10,
            configuration: .init(
                maximumWindowDuration: 6,
                boundaryContextDuration: 0.25,
                maximumMergeGap: 0.5
            )
        )
        #expect(chunks.map(\.ownershipStart) == [0, 7])
        #expect(chunks.map(\.ownershipEnd) == [2, 9])

        let invalid = ASRChunkPlanner.chunks(
            speechRanges: [.init(start: 0, end: 1)],
            audioDuration: 10,
            configuration: .init(
                maximumWindowDuration: 0,
                boundaryContextDuration: 0,
                maximumMergeGap: 0
            )
        )
        #expect(invalid.isEmpty)
    }

    @Test func transcriptOffsetsPreserveSpeakersAndDurations() {
        let input = TranscriptionResult(
            text: "Hello world",
            language: "en",
            words: [
                .init(text: "Hello", start: 0.1, end: 0.5, speaker: "Speaker 1"),
                .init(text: "world", start: 0.6, end: 1.0, speaker: "Speaker 2"),
            ],
            segments: [
                .init(text: "Hello", start: 0.1, end: 0.5, speaker: "Speaker 1"),
                .init(text: "world", start: 0.6, end: 1.0, speaker: "Speaker 2"),
            ]
        )

        let shifted = input.offsetting(by: 12.5)
        #expect(abs((shifted.words[0].start ?? 0) - 12.6) < 0.000_001)
        #expect(abs((shifted.words[1].end ?? 0) - 13.5) < 0.000_001)
        #expect(shifted.words.map(\.speaker) == input.words.map(\.speaker))
        #expect(abs((shifted.segments[0].end - shifted.segments[0].start) - 0.4) < 0.000_001)
    }

    @Test func rangeFilterKeepsOverlappingTimedContent() {
        let input = TranscriptionResult(
            text: "one two three",
            language: "en",
            words: [
                .init(text: "one", start: 0, end: 0.6, speaker: "Speaker 1"),
                .init(text: "two", start: 0.7, end: 1.2, speaker: "Speaker 1"),
                .init(text: "three", start: 1.3, end: 2, speaker: "Speaker 2"),
            ],
            segments: [
                .init(text: "one two", start: 0, end: 1.2, speaker: "Speaker 1"),
                .init(text: "three", start: 1.3, end: 2, speaker: "Speaker 2"),
            ]
        )

        let filtered = TranscriptCache.filter(input, to: 0.8...1.4)
        #expect(filtered.words.map(\.text) == ["two", "three"])
        #expect(filtered.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func transcriptFittingPreservesTailWordsInsideEditorClip() {
        let input = TranscriptionResult(
            text: "We need to fight for our people.",
            language: "en",
            words: [
                .init(text: "We", start: 59.60, end: 59.76, speaker: "Speaker 2"),
                .init(text: "need", start: 59.84, end: 60.00, speaker: "Speaker 2"),
                .init(text: "to", start: 60.00, end: 60.08, speaker: "Speaker 2"),
                .init(text: "fight", start: 60.08, end: 60.24, speaker: "Speaker 2"),
                .init(text: "people.", start: 60.40, end: 60.56, speaker: "Speaker 2"),
            ],
            segments: [
                .init(text: "We need to fight for our people.", start: 59.60, end: 60.56, speaker: "Speaker 2"),
            ]
        )

        let fitted = input.fittingTimestamps(to: 59.9)
        #expect(fitted.words.count == input.words.count)
        #expect(fitted.words.allSatisfy { ($0.start ?? -1) >= 0 && ($0.end ?? 60) <= 59.9 })
        #expect(fitted.words.allSatisfy { ($0.end ?? 0) > ($0.start ?? 0) })
        #expect(zip(fitted.words, fitted.words.dropFirst()).allSatisfy { pair in
            (pair.0.start ?? 0) <= (pair.1.start ?? 0)
        })
        #expect(abs((fitted.words.last?.end ?? 0) - 59.9) < 0.000_001)
        #expect(fitted.segments.last?.end == 59.9)
    }

    @Test func interruptedJobsRecoverAsCleanRetriesOnLaunch() {
        var transcription = WorkbenchTranscriptionJob(sourcePath: "/tmp/interrupted.wav")
        transcription.state = .running
        transcription.progress = 0.74
        transcription.progressMessage = "Segmenting 38/236"
        transcription.errorMessage = "stale"

        let recoveredTranscription = WorkbenchStore.recoveredForLaunch(transcription)
        #expect(recoveredTranscription.state == .ready)
        #expect(recoveredTranscription.progress == 0)
        #expect(recoveredTranscription.progressMessage == "Interrupted — ready to retry")
        #expect(recoveredTranscription.errorMessage == nil)

        var dub = WorkbenchDubJob()
        dub.state = .ready
        dub.progress = 0.51
        dub.progressMessage = "Generating local speech…"

        let recoveredDub = WorkbenchStore.recoveredForLaunch(dub)
        #expect(recoveredDub.state == .ready)
        #expect(recoveredDub.progress == 0)
        #expect(recoveredDub.progressMessage == "Interrupted — ready to retry")
    }

    @Test func automaticSummaryAcceptsTheUnassignedGeneralTemplate() {
        #expect(
            WorkbenchStore.summaryTemplateMatches(
                requestedTemplateID: SummaryTemplateDefinition.generalSummaryID,
                currentTemplateID: nil,
                allowUnassignedDefault: true
            )
        )
        #expect(
            !WorkbenchStore.summaryTemplateMatches(
                requestedTemplateID: SummaryTemplateDefinition.generalSummaryID,
                currentTemplateID: nil
            )
        )
        #expect(
            !WorkbenchStore.summaryTemplateMatches(
                requestedTemplateID: SummaryTemplateDefinition.generalSummaryID,
                currentTemplateID: "custom-template",
                allowUnassignedDefault: true
            )
        )
        #expect(
            WorkbenchStore.summaryTemplateMatches(
                requestedTemplateID: "custom-template",
                currentTemplateID: "CUSTOM-TEMPLATE"
            )
        )
    }

    @Test func staleSummaryStateRetriesWhenNoSummaryWasPersisted() {
        var transcription = WorkbenchTranscriptionJob(sourcePath: "/tmp/stale-summary.wav")
        transcription.state = .completed
        transcription.summaryState = .running
        transcription.summaryErrorMessage = "stale"

        let recovered = WorkbenchStore.recoveredForLaunch(transcription)

        #expect(recovered.state == .completed)
        #expect(recovered.summaryState == nil)
        #expect(recovered.summaryErrorMessage == nil)
        #expect(recovered.progressMessage == "Transcript ready — summary will retry")
    }

    @Test func staleSummaryStatePreservesTheLastSuccessfulSummary() {
        var transcription = WorkbenchTranscriptionJob(sourcePath: "/tmp/previous-summary.wav")
        transcription.state = .completed
        transcription.summaryMarkdown = "## Previous summary"
        transcription.summaryState = .running
        transcription.summaryErrorMessage = "stale"

        let recovered = WorkbenchStore.recoveredForLaunch(transcription)

        #expect(recovered.summaryMarkdown == "## Previous summary")
        #expect(recovered.summaryState == .completed)
        #expect(recovered.summaryErrorMessage == nil)
        #expect(recovered.progressMessage == "Transcript and summary ready")
    }

    @Test func runningSummaryWithoutOutputNeedsGeneration() {
        #expect(WorkbenchStore.summaryNeedsGeneration(markdown: nil, state: .running))
        #expect(!WorkbenchStore.summaryNeedsGeneration(markdown: "## Summary", state: .running))
        #expect(!WorkbenchStore.summaryNeedsGeneration(markdown: nil, state: .completed))
    }

    @Test func applyingTemplateReplacesAutomaticSummaryGeneration() {
        var registry = SummaryTaskRegistry()
        let id = UUID()
        let automaticGeneration = registry.begin(for: id)
        #expect(automaticGeneration != nil)
        guard let automaticGeneration else { return }

        let appliedGeneration = registry.begin(for: id, replacingExisting: true)
        #expect(appliedGeneration != nil)
        guard let appliedGeneration else { return }

        #expect(!registry.owns(id, generation: automaticGeneration))
        #expect(registry.owns(id, generation: appliedGeneration))
        registry.finish(for: id, generation: automaticGeneration)
        #expect(registry.owns(id, generation: appliedGeneration))
        registry.finish(for: id, generation: appliedGeneration)
        #expect(!registry.owns(id, generation: appliedGeneration))
    }

    @Test func newDubDraftRetainsOnlyTheLatestSettingsAndReference() {
        let voiceID = UUID()
        var earlier = WorkbenchDubJob()
        earlier.modifiedAt = Date(timeIntervalSinceReferenceDate: 1)
        earlier.language = "en"
        earlier.script = "Earlier script"

        var latest = WorkbenchDubJob()
        latest.modifiedAt = Date(timeIntervalSinceReferenceDate: 2)
        latest.title = "Previous dub"
        latest.language = "zh"
        latest.model = .medium
        latest.referenceAudioPath = "/tmp/reference.wav"
        latest.referenceText = "Reference transcript"
        latest.referenceVoiceID = voiceID
        latest.speakerVoiceIDs = ["Speaker 1": UUID()]
        let segmentVoiceID = UUID()
        latest.segmentVoiceIDs = [0: segmentVoiceID]
        latest.sourceTranscriptionID = UUID()
        latest.outputPath = "/tmp/previous.wav"
        latest.script = "Previous script"
        latest.segments = [DubSegmentPayload(index: 0, text: "Previous script")]

        let draft = WorkbenchStore.newDubJob(
            from: [earlier, latest],
            preferredLanguage: "en"
        )

        #expect(draft.title.isEmpty)
        #expect(draft.script.isEmpty)
        #expect(draft.segments == [DubSegmentPayload(index: 0, text: "")])
        #expect(draft.sourceTranscriptionID == nil)
        #expect(draft.outputPath == nil)
        #expect(draft.speakerVoiceIDs == nil)
        #expect(draft.segmentVoiceIDs == [0: segmentVoiceID])
        #expect(draft.language == "zh")
        #expect(draft.model == .medium)
        #expect(draft.referenceAudioPath == "/tmp/reference.wav")
        #expect(draft.referenceText == "Reference transcript")
        #expect(draft.referenceVoiceID == voiceID)
    }

    @Test func newDubDraftResolvesAutomaticLanguageToThePreferredLanguage() {
        var previous = WorkbenchDubJob()
        previous.language = "auto"

        let draft = WorkbenchStore.newDubJob(
            from: [previous],
            preferredLanguage: "en"
        )

        #expect(draft.language == "en")
    }

    @Test func localTranscriptionAdmissionRejectsEmptyAndOversizedBatches() throws {
        #expect(throws: LocalTranscriptionResourcePolicy.AdmissionError.self) {
            try LocalTranscriptionResourcePolicy.admit([])
        }

        let urls = (0..<LocalTranscriptionResourcePolicy.maxFilesPerBatch + 1).map {
            URL(fileURLWithPath: "/tmp/voxella-batch-\($0).wav")
        }
        #expect(throws: LocalTranscriptionResourcePolicy.AdmissionError.self) {
            try LocalTranscriptionResourcePolicy.admit(urls)
        }
    }

    @Test func processingOptionsClipAndTranslationMapIntoMediaFlow() {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/clip.wav")
        job.languageCode = "en"
        job.speakerCount = .two
        job.clipStartMs = 1_500
        job.clipEndMs = 8_000
        job.targetLanguageCode = "zh-CN"

        #expect(job.clipRangeSeconds == 1.5...8.0)

        let steps = WorkbenchMediaFlowPlanner.transcriptionSteps(for: job, hasAPIKey: true)
        guard case .transcribe(let payload) = steps.first else {
            Issue.record("expected transcribe step")
            return
        }
        #expect(payload.languageCode == "en")
        #expect(payload.speakerCount == 2)
        #expect(payload.clipRangeSeconds == 1.5...8.0)
        #expect(steps.contains {
            if case .prepareSubtitles = $0 { return true }
            return false
        })
        #expect(steps.contains {
            if case .translate(let translation) = $0 {
                return translation.targetLanguage == "zh-CN"
            }
            return false
        })
    }

    @Test @MainActor
    func stagingMediaImportOpensTranscribeOptionsFlow() throws {
        let store = WorkbenchStore.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxella-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a.wav")
        let second = directory.appendingPathComponent("b.wav")
        try Data().write(to: first)
        try Data().write(to: second)

        store.stageMediaImport([first, second])
        #expect(store.pendingMediaImportURLs.count == 2)
        #expect(store.route == .transcribe)
        #expect(store.selectedTranscriptionID == nil)

        store.clearPendingMediaImport()
        #expect(store.pendingMediaImportURLs.isEmpty)
    }

    @Test func appendingPipelineWarningPreservesDiarizationMetrics() {
        var diagnostics = DiarizationDiagnostics(
            backend: .mlxStreamingSortformer,
            elapsedSeconds: 12.5,
            processedChunks: 7,
            detectedSpeakerCount: 2,
            requestedSpeakerCount: 2,
            warnings: ["existing warning"]
        )
        diagnostics.modelRevision = "revision"
        diagnostics.realTimeFactor = 0.42
        diagnostics.peakMLXMemoryBytes = 123_456
        diagnostics.speechCoverage = 0.41
        diagnostics.processedAudioDuration = 180
        diagnostics.chunkDuration = 15.04
        diagnostics.fifoMax = 0
        diagnostics.spkcacheMax = 188

        let updated = diagnostics.addingWarning("alignment warning")

        #expect(updated.backend == diagnostics.backend)
        #expect(updated.elapsedSeconds == diagnostics.elapsedSeconds)
        #expect(updated.processedChunks == diagnostics.processedChunks)
        #expect(updated.detectedSpeakerCount == diagnostics.detectedSpeakerCount)
        #expect(updated.requestedSpeakerCount == diagnostics.requestedSpeakerCount)
        #expect(updated.modelRevision == diagnostics.modelRevision)
        #expect(updated.realTimeFactor == diagnostics.realTimeFactor)
        #expect(updated.peakMLXMemoryBytes == diagnostics.peakMLXMemoryBytes)
        #expect(updated.speechCoverage == diagnostics.speechCoverage)
        #expect(updated.processedAudioDuration == diagnostics.processedAudioDuration)
        #expect(updated.chunkDuration == diagnostics.chunkDuration)
        #expect(updated.fifoMax == diagnostics.fifoMax)
        #expect(updated.spkcacheMax == diagnostics.spkcacheMax)
        #expect(updated.warnings == ["existing warning", "alignment warning"])
    }

    @Test func editedTranscriptAnchorsAreMonotonicAndScriptNeutral() {
        let old = ["Hello,", "世界", "from", "Voxella."]
        let new = ["Hello", "brave", "世界", "from", "Voxella!"]
        let matches = AlignmentAnchorMatcher.matchingPairs(old: old, new: new)

        #expect(matches.map(\.old) == [0, 1, 2, 3])
        #expect(matches.map(\.new) == [0, 2, 3, 4])
        #expect(zip(matches, matches.dropFirst()).allSatisfy { pair in
            pair.0.old < pair.1.old && pair.0.new < pair.1.new
        })
    }

    @Test func alignmentAnchorsHandleRTLCombiningMarksAndEmojiGenerically() {
        let old = ["مرحبًا،", "العالم!", "नमस्ते", "🌍"]
        let new = ["مرحبًا", "الجديد", "العالم", "नमस्ते", "🌎"]
        let matches = AlignmentAnchorMatcher.matchingPairs(old: old, new: new)

        #expect(matches.map(\.old) == [0, 1, 2])
        #expect(matches.map(\.new) == [0, 2, 3])
        #expect(AlignmentAnchorMatcher.normalized("🌍").isEmpty)
    }

    @Test func alignmentTimestampGeometryRejectsLongCJKUnitAgainstLocalTiming() {
        let outlier = AlignmentTimestampGeometry.excessiveUnit(in: [
            .init(text: "刚", start: 0, end: 0.08),
            .init(text: "刚", start: 0.08, end: 4.4),
            .init(text: "听", start: 4.4, end: 4.52),
            .init(text: "那", start: 4.52, end: 4.62),
        ])

        #expect(outlier?.unitIndex == 1)
        #expect(outlier?.duration == 4.32)
    }

    @Test func alignmentTimestampGeometryAllowsLongSilenceBetweenWords() {
        let outlier = AlignmentTimestampGeometry.excessiveUnit(in: [
            .init(text: "开", start: 0, end: 0.12),
            .init(text: "始", start: 9.1, end: 9.24),
            .init(text: "吧", start: 9.24, end: 9.38),
        ])

        #expect(outlier == nil)
    }

    @Test func alignmentTimestampGeometryRejectsStretchedCJKClusterWithoutMedianEscape() {
        let outlier = AlignmentTimestampGeometry.excessiveUnit(in: [
            .init(text: "刚", start: 0, end: 4.3),
            .init(text: "听", start: 4.3, end: 8.6),
            .init(text: "那", start: 8.6, end: 12.9),
        ])

        #expect(outlier?.unitIndex == 0)
        #expect(outlier?.duration == 4.3)
    }

    #if BUNDLED_SPEECH
    @Test func alignmentCoalescesFineSpansByModelCapabilityWithoutLanguageRules() throws {
        var capabilities = AlignmentModelCapabilities.qwen3ForcedAligner
        capabilities.targetChunkDuration = 10
        capabilities.maximumChunkDuration = 12
        let chunks = try LongFormAlignmentEngine.alignmentChunks(
            from: [
                .init(text: "Hello", startTime: 0, endTime: 2),
                .init(text: "世界", startTime: 2.1, endTime: 5),
                .init(text: "مرحبا", startTime: 9, endTime: 11),
                .init(text: "again", startTime: 12, endTime: 14),
            ],
            capabilities: capabilities
        )

        #expect(chunks.count == 3)
        #expect(chunks[0].text == "Hello 世界")
        #expect(chunks[0].startTime == 0 && chunks[0].endTime == 5)
        #expect(chunks[1].text == "مرحبا")
        #expect(chunks[1].startTime == 9 && chunks[1].endTime == 11)
        #expect(chunks[2].text == "again")
        #expect(chunks[2].startTime == 12 && chunks[2].endTime == 14)
        #expect(chunks.allSatisfy { $0.duration <= capabilities.targetChunkDuration })
    }

    @Test func coarseAlignmentFallbackPreservesEveryUnitAndSpanBounds() {
        let units = ["你", "好", "مرحبا", "world"]
        let words = LongFormAlignmentEngine.evenlyTimed(
            units: units,
            within: .init(text: units.joined(separator: " "), startTime: 12.5, endTime: 14.5)
        )

        #expect(words.map(\.text) == units)
        #expect(words.first?.startTime == 12.5)
        #expect(words.last?.endTime == 14.5)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.endTime == $1.startTime })
    }

    @Test func coarseAlignmentFallbackLeavesLongSpanRemainderAsSilence() {
        let words = LongFormAlignmentEngine.evenlyTimed(
            units: ["你", "好", "吗"],
            within: .init(text: "你 好 吗", startTime: 0, endTime: 12)
        )

        #expect(words.allSatisfy { $0.endTime - $0.startTime <= 2 })
        #expect(words[1].startTime - words[0].endTime > 0)
    }

    @Test func alignmentRetriesUnstableChunksBeforeUsingCoarseTiming() {
        var capabilities = AlignmentModelCapabilities.qwen3ForcedAligner
        capabilities.contextDuration = 0.5
        capabilities.minimumRetryUnitCount = 4
        capabilities.maximumRetryDepth = 2

        #expect(LongFormAlignmentEngine.canRetry(
            spanDuration: 12,
            unitCount: 4,
            retryDepth: 0,
            capabilities: capabilities
        ))
        #expect(!LongFormAlignmentEngine.canRetry(
            spanDuration: 12,
            unitCount: 4,
            retryDepth: 2,
            capabilities: capabilities
        ))
        #expect(!LongFormAlignmentEngine.canRetry(
            spanDuration: 1,
            unitCount: 4,
            retryDepth: 0,
            capabilities: capabilities
        ))
    }
    #endif

    @Test func diarizationTimelinePreservesOverlapAndUsesProbabilityEvidence() {
        let probabilities: [Float] = [
            0.8, 0.1,
            0.8, 0.7,
            0.1, 0.8,
            0.1, 0.8,
        ]
        var policy = SpeakerDiarizationPolicy.standard(requestedSpeakerCount: 2)
        policy.onsetThreshold = 0.6
        policy.offsetThreshold = 0.4
        policy.minimumTurnDuration = 0
        policy.mergeGap = 0
        let timeline = SpeakerActivityPostprocessor.makeTimeline(
            probabilities: probabilities,
            frameDuration: 0.1,
            speakerCapacity: 2,
            audioDuration: 0.4,
            speechRanges: [.init(start: 0, end: 0.4)],
            policy: policy,
            backend: .mlxStreamingSortformer,
            elapsedSeconds: 0.1,
            processedChunks: 1
        )

        #expect(timeline.speakerCount == 2)
        #expect(timeline.intervals.contains { $0.speakerID == 0 && $0.start == 0 && $0.end == 0.2 })
        #expect(timeline.intervals.contains { $0.speakerID == 1 && $0.start == 0.1 && $0.end == 0.4 })
        #expect(timeline.speakerForWord(start: 0, end: 0.09) == 0)
        #expect(timeline.speakerForWord(start: 0.25, end: 0.35) == 1)
    }

    @Test func diarizationTimelineGatesNonspeechWithoutLanguageRules() {
        let timeline = SpeakerActivityPostprocessor.makeTimeline(
            probabilities: [0.9, 0.9, 0.9, 0.9],
            frameDuration: 0.1,
            speakerCapacity: 1,
            audioDuration: 0.4,
            speechRanges: [.init(start: 0.1, end: 0.3)],
            policy: .standard(requestedSpeakerCount: 1),
            backend: .mlxStreamingSortformer,
            elapsedSeconds: 0,
            processedChunks: 1
        )

        #expect(timeline.probabilities == [0, 0.9, 0.9, 0])
        #expect(timeline.intervals.count == 1)
        #expect(timeline.intervals[0].start == 0.1)
        #expect(abs(timeline.intervals[0].end - 0.3) < 0.000_001)
    }

    @Test func transcriptCacheIdentityIncludesSchemaModelsAndSpeakerPolicy() {
        let automatic = TranscriptCache.localPipelineFingerprint(configuration: .automatic)
        let englishSingle = TranscriptCache.localPipelineFingerprint(
            configuration: .init(languageCode: "en", speakerCount: 1)
        )
        let englishTwo = TranscriptCache.localPipelineFingerprint(
            configuration: .init(languageCode: "en", speakerCount: 2)
        )

        #expect(automatic.contains("schema=\(TranscriptCache.localPipelineSchemaVersion)"))
        let whisperFallback = LocalModelManager.preferredWhisperFallbackModelID()
        #expect(automatic.contains("whisper=\(whisperFallback.rawValue)"))
        #expect(automatic.contains(LocalModelManager.catalog.first { $0.id == whisperFallback }!.revision))
        #expect(automatic.contains(LocalModelManager.catalog.first { $0.id == .qwen3ASR17B8Bit }!.revision))
        #expect(automatic.contains(LocalModelManager.catalog.first { $0.id == .parakeetTDT06Bv3 }!.revision))
        #expect(automatic.contains(LocalModelManager.catalog.first { $0.id == .forcedAligner }!.revision))
        #expect(automatic != englishSingle)
        #expect(englishSingle != englishTwo)
    }

    #if BUNDLED_SPEECH
    @Test func captionSegmentationHandlesSpeakerChangesAndCJKSpacing() {
        let words = [
            TranscriptionWord(text: "你", start: 0, end: 0.2, speaker: "Speaker 1"),
            TranscriptionWord(text: "好", start: 0.2, end: 0.4, speaker: "Speaker 1"),
            TranscriptionWord(text: "world", start: 0.5, end: 0.9, speaker: "Speaker 2"),
            TranscriptionWord(text: "!", start: 0.9, end: 1, speaker: "Speaker 2"),
        ]

        let segments = LocalSpeechPipeline.makeSegments(from: words)
        #expect(segments.count == 2)
        #expect(segments[0].text == "你好")
        #expect(segments[1].text == "world!")
        #expect(segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func localLanguageDetectionFeedsTheForcedAligner() {
        #expect(LocalSpeechPipeline.detectLanguageCode(in: "Welcome to this local transcription test.") == "en")
        #expect(LocalSpeechPipeline.detectLanguageCode(in: "欢迎使用本地转写和词级时间戳。") == "zh-Hans")
    }

    @Test func dubAutoLanguageUsesTheLocalScript() {
        #expect(LocalDubPipeline.ttsLanguage("auto", script: "Welcome to the local dubbing test.") == "english")
        #expect(LocalDubPipeline.ttsLanguage("auto", script: "欢迎使用本地配音功能。") == "chinese")
        #expect(LocalDubPipeline.ttsLanguage("pt-BR", script: "Olá") == "portuguese")
    }

    /// Opt-in installer used by release qualification on a real Apple Silicon Mac.
    /// It is skipped in ordinary unit-test runs; the product UI remains the normal
    /// user-facing way to authorize each network download.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_INSTALL_LOCAL_MODELS"] == "1"))
    func installAndVerifyPinnedLocalModels() async throws {
        let manager = LocalModelManager.shared
        manager.acceptLicense(.sortformerDiarization)
        for model in LocalModelManager.catalog where !model.isLegacy {
            manager.refreshInstallationStates()
            if manager.state(for: model.id).isInstalled { continue }
            manager.download(model.id)
            while manager.state(for: model.id).isBusy {
                try await Task.sleep(for: .milliseconds(500))
            }
            if case .failed(let message) = manager.state(for: model.id) {
                Issue.record("\(model.title) installation failed: \(message)")
            }
            #expect(manager.state(for: model.id).isInstalled)
            #expect(LocalModelManager.isInstalled(model))
        }
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_INSTALL_LARGE_TURBO_8BIT"] == "1"))
    func installAndSelectRecommendedLargeTurboASR() async throws {
        let manager = LocalModelManager.shared
        manager.downloadAndUseASRModel(.whisperLargeV3Turbo8Bit)
        while manager.state(for: .whisperLargeV3Turbo8Bit).isBusy {
            try await Task.sleep(for: .milliseconds(500))
        }
        if case .failed(let message) = manager.state(for: .whisperLargeV3Turbo8Bit) {
            Issue.record("Whisper Large v3 Turbo 8-bit installation failed: \(message)")
        }
        #expect(manager.state(for: .whisperLargeV3Turbo8Bit).isInstalled)
        #expect(manager.activeASRModelID == .whisperLargeV3Turbo8Bit)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_INSTALL_SORTFORMER"] == "1"))
    func installAcceptedSortformerDiarizationModel() async throws {
        let manager = LocalModelManager.shared
        manager.acceptLicense(.sortformerDiarization)
        manager.download(.sortformerDiarization)
        while manager.state(for: .sortformerDiarization).isBusy {
            try await Task.sleep(for: .milliseconds(500))
        }
        if case .failed(let message) = manager.state(for: .sortformerDiarization) {
            Issue.record("Streaming Sortformer installation failed: \(message)")
        }
        #expect(manager.state(for: .sortformerDiarization).isInstalled)
        #expect(
            LocalModelManager.isInstalled(
                LocalModelManager.catalog.first { $0.id == .sortformerDiarization }!
            )
        )
    }
    #endif
}
