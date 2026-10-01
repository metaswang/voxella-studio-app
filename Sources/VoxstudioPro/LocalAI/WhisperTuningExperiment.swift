import AVFoundation
import Foundation

#if BUNDLED_SPEECH
import MLX
import MLXAudioSTT

/// Parameters that are effective in the app's local MLX Whisper implementation.
///
/// The Modal/faster-whisper parameters are deliberately kept in the experiment
/// report as a separate compatibility layer. They are not silently renamed into
/// parameters that mlx-audio-swift does not implement.
struct WhisperASRTuningProfile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let temperature: Float
    let topP: Float
    let topK: Int
    let repetitionPenalty: Float
    let repetitionContextSize: Int
    let seed: UInt64

    static let matrix: [WhisperASRTuningProfile] = [
        .init(
            id: "p0_app_current",
            label: "App current",
            temperature: 0,
            topP: 1,
            topK: 0,
            repetitionPenalty: 1,
            repetitionContextSize: 32,
            seed: 0
        ),
        .init(
            id: "p1_modal_balanced_proxy",
            label: "Modal balanced proxy",
            temperature: 0,
            topP: 1,
            topK: 0,
            repetitionPenalty: 1.10,
            repetitionContextSize: 32,
            seed: 11
        ),
        .init(
            id: "p2_modal_guarded",
            label: "Modal guarded",
            temperature: 0,
            topP: 1,
            topK: 0,
            repetitionPenalty: 1.10,
            repetitionContextSize: 64,
            seed: 22
        ),
        .init(
            id: "p3_mlx_conservative",
            label: "MLX conservative sampling",
            temperature: 0.15,
            topP: 0.95,
            topK: 50,
            repetitionPenalty: 1.05,
            repetitionContextSize: 64,
            seed: 33
        ),
        .init(
            id: "p4_mlx_sampling",
            label: "MLX sampling",
            temperature: 0.20,
            topP: 0.95,
            topK: 50,
            repetitionPenalty: 1.10,
            repetitionContextSize: 64,
            seed: 44
        ),
        .init(
            id: "p5_recommended_greedy",
            label: "Recommended greedy",
            temperature: 0,
            topP: 1,
            topK: 0,
            repetitionPenalty: 1.05,
            repetitionContextSize: 64,
            seed: 55
        ),
    ]

    func generationParameters(language: String?) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: 8192,
            temperature: temperature,
            topP: topP,
            topK: topK,
            verbose: false,
            language: language,
            chunkDuration: 30,
            minChunkDuration: 0.1,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize
        )
    }
}

struct WhisperTuningDecodeStats: Codable, Sendable {
    let text: String
    let language: String?
    let segmentCount: Int
    let promptTokens: Int
    let generationTokens: Int
    let totalTokens: Int
    let elapsedSeconds: Double
    let realTimeFactor: Double
    let peakMemoryGB: Double
    let vadEnabled: Bool
    let vadElapsedSeconds: Double
    let vadModelRevision: String?
    let vadCandidateRangeCount: Int
    let vadAcceptedRangeCount: Int
    let vadInputDurationSeconds: Double
    let vadAcceptedDurationSeconds: Double
}

struct WhisperTuningTextMetrics: Codable, Sendable {
    let referenceTokenCount: Int
    let candidateTokenCount: Int
    let editDistance: Int
    let tokenErrorRate: Double
    let normalizedSimilarity: Double
    let lengthRatio: Double
}

struct WhisperTuningSession: Codable, Sendable {
    let sessionID: UUID
    let title: String
    let sourcePath: String
    let sourceDurationSeconds: Double
    let evaluatedStartSeconds: Double
    let evaluatedEndSeconds: Double
    let sourceASREngine: String?
    let sourceLanguage: String?
    let referenceText: String
}

struct WhisperTuningRun: Codable, Sendable {
    let session: WhisperTuningSession
    let profile: WhisperASRTuningProfile
    let decode: WhisperTuningDecodeStats?
    let textMetrics: WhisperTuningTextMetrics?
    let error: String?
}

#if BUNDLED_SPEECH
struct WhisperProductionReplayParameters: Codable, Sendable {
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let verbose: Bool
    let language: String?
    let chunkDuration: Float
    let minChunkDuration: Float
    let repetitionPenalty: Float
    let repetitionContextSize: Int
    let kvBits: Int?
    let kvGroupSize: Int
    let quantizedKVStart: Int

    init(_ parameters: STTGenerateParameters) {
        maxTokens = parameters.maxTokens
        temperature = parameters.temperature
        topP = parameters.topP
        topK = parameters.topK
        verbose = parameters.verbose
        language = parameters.language
        chunkDuration = parameters.chunkDuration
        minChunkDuration = parameters.minChunkDuration
        repetitionPenalty = parameters.repetitionPenalty
        repetitionContextSize = parameters.repetitionContextSize
        kvBits = parameters.kvBits
        kvGroupSize = parameters.kvGroupSize
        quantizedKVStart = parameters.quantizedKVStart
    }
}

struct WhisperProductionReplayChunk: Codable, Sendable {
    let index: Int
    let inputStart: Double
    let inputEnd: Double
    let ownershipStart: Double
    let ownershipEnd: Double
    let inputSampleCount: Int
    let text: String
    let language: String?
    let promptTokens: Int
    let generationTokens: Int
    let totalTokens: Int
    let elapsedSeconds: Double
}

struct WhisperProductionReplay: Codable, Sendable {
    let generatedAt: Date
    let sourcePath: String
    let clipStartSeconds: Double
    let clipEndSeconds: Double
    let decodedSampleCount: Int
    let preparedSampleCount: Int
    let decodedDurationSeconds: Double
    let originalRMSDBFS: Double
    let originalPeakDBFS: Double
    let processedRMSDBFS: Double
    let processedPeakDBFS: Double
    let rescueGainDB: Double
    let vadCandidateRanges: [ASRSpeechRange]
    let vadAcceptedRanges: [ASRSpeechRange]
    let sceneVetoedRanges: [ASRSpeechRange]
    let finalAllowedSpeechRanges: [ASRSpeechRange]
    let chunkConfiguration: ASRChunkPlannerConfiguration
    let chunks: [WhisperProductionReplayChunk]
    let routeEngine: ASREngine
    let routeReason: String
    let routeTopLanguage: String?
    let whisperHint: String?
    let languagePrompt: String?
    let routeConfidence: Float
    let routeSpeechDuration: Double
    let qwenCoverage: Float
    let parakeetCoverage: Float
    let whisperCoverage: Float
    let qwenVote: Float
    let parakeetVote: Float
    let whisperVote: Float
    let modelID: String
    let modelRepository: String
    let modelRevision: String
    let generationParameters: WhisperProductionReplayParameters
    let firstPassRawText: String?
    let finalRawText: String?
}

struct WhisperProductionReplayRun: Codable, Sendable {
    let session: WhisperTuningSession
    let replay: WhisperProductionReplay?
    let error: String?
}

struct WhisperProductionReplayOutput: Codable, Sendable {
    let generatedAt: Date
    let languageHint: String?
    let runs: [WhisperProductionReplayRun]
}

final class WhisperProductionReplayCollector {
    private(set) var sourcePath = ""
    private(set) var clipStartSeconds = 0.0
    private(set) var clipEndSeconds = 0.0
    private(set) var decodedSampleCount = 0
    private(set) var preparedSampleCount = 0
    private(set) var decodedDurationSeconds = 0.0
    private(set) var originalRMSDBFS = 0.0
    private(set) var originalPeakDBFS = 0.0
    private(set) var processedRMSDBFS = 0.0
    private(set) var processedPeakDBFS = 0.0
    private(set) var rescueGainDB = 0.0
    private(set) var vadCandidateRanges: [ASRSpeechRange] = []
    private(set) var vadAcceptedRanges: [ASRSpeechRange] = []
    private(set) var sceneVetoedRanges: [ASRSpeechRange] = []
    private(set) var finalAllowedSpeechRanges: [ASRSpeechRange] = []
    private(set) var chunkConfiguration = ASRChunkPlannerConfiguration(
        maximumWindowDuration: 0,
        boundaryContextDuration: 0,
        maximumMergeGap: 0
    )
    private(set) var chunks: [WhisperProductionReplayChunk] = []
    private(set) var route: ASREngineRouteDecision?
    private(set) var languagePrompt: String?
    private(set) var modelID = ""
    private(set) var modelRepository = ""
    private(set) var modelRevision = ""
    private(set) var generationParameters: WhisperProductionReplayParameters?
    private(set) var firstPassRawText: String?
    private(set) var finalRawText: String?

    func setSource(
        path: String,
        clipStart: Double,
        clipEnd: Double,
        decodedSamples: Int,
        preparedSamples: Int,
        decodedDuration: Double,
        original: ASRAudioLevelMetrics,
        processed: ASRAudioLevelMetrics,
        rescueGain: Double
    ) {
        sourcePath = path
        clipStartSeconds = clipStart
        clipEndSeconds = clipEnd
        decodedSampleCount = decodedSamples
        preparedSampleCount = preparedSamples
        decodedDurationSeconds = decodedDuration
        originalRMSDBFS = original.rmsDBFS
        originalPeakDBFS = original.peakDBFS
        processedRMSDBFS = processed.rmsDBFS
        processedPeakDBFS = processed.peakDBFS
        rescueGainDB = rescueGain
    }

    func setSpeechRanges(
        candidate: [ASRSpeechRange],
        accepted: [ASRSpeechRange],
        sceneVetoed: [ASRSpeechRange],
        finalAllowed: [ASRSpeechRange]
    ) {
        vadCandidateRanges = candidate
        vadAcceptedRanges = accepted
        sceneVetoedRanges = sceneVetoed
        finalAllowedSpeechRanges = finalAllowed
    }

    func setRoute(_ route: ASREngineRouteDecision, languagePrompt: String?) {
        self.route = route
        self.languagePrompt = languagePrompt
    }

    func setChunks(_ chunks: [ASRRecognitionChunk], configuration: ASRChunkPlannerConfiguration) {
        chunkConfiguration = configuration
        self.chunks = []
        self.chunks.reserveCapacity(chunks.count)
    }

    func setModel(id: LocalModelID, descriptor: LocalModelDescriptor) {
        modelID = id.rawValue
        modelRepository = descriptor.repository
        modelRevision = descriptor.revision
    }

    func setGenerationParameters(_ parameters: STTGenerateParameters) {
        generationParameters = WhisperProductionReplayParameters(parameters)
    }

    func recordChunk(_ chunk: ASRRecognitionChunk, output: STTOutput, sampleCount: Int) {
        chunks.append(.init(
            index: chunks.count + 1,
            inputStart: chunk.inputStart,
            inputEnd: chunk.inputEnd,
            ownershipStart: chunk.ownershipStart,
            ownershipEnd: chunk.ownershipEnd,
            inputSampleCount: sampleCount,
            text: output.text,
            language: output.language,
            promptTokens: output.promptTokens,
            generationTokens: output.generationTokens,
            totalTokens: output.totalTokens,
            elapsedSeconds: output.totalTime
        ))
    }

    func setFirstPassRawText(_ text: String) {
        firstPassRawText = text
    }

    func setFinalRawText(_ text: String) {
        finalRawText = text
    }

    func makeReplay() throws -> WhisperProductionReplay {
        guard let route, let generationParameters else {
            throw NSError(
                domain: "WhisperProductionReplay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Replay did not capture route or generation parameters."]
            )
        }
        return WhisperProductionReplay(
            generatedAt: Date(),
            sourcePath: sourcePath,
            clipStartSeconds: clipStartSeconds,
            clipEndSeconds: clipEndSeconds,
            decodedSampleCount: decodedSampleCount,
            preparedSampleCount: preparedSampleCount,
            decodedDurationSeconds: decodedDurationSeconds,
            originalRMSDBFS: originalRMSDBFS,
            originalPeakDBFS: originalPeakDBFS,
            processedRMSDBFS: processedRMSDBFS,
            processedPeakDBFS: processedPeakDBFS,
            rescueGainDB: rescueGainDB,
            vadCandidateRanges: vadCandidateRanges,
            vadAcceptedRanges: vadAcceptedRanges,
            sceneVetoedRanges: sceneVetoedRanges,
            finalAllowedSpeechRanges: finalAllowedSpeechRanges,
            chunkConfiguration: chunkConfiguration,
            chunks: chunks,
            routeEngine: route.engine,
            routeReason: route.reason.rawValue,
            routeTopLanguage: route.topLanguage,
            whisperHint: route.whisperHint,
            languagePrompt: languagePrompt,
            routeConfidence: route.routeConfidence,
            routeSpeechDuration: route.speechDuration,
            qwenCoverage: route.scores.qwen,
            parakeetCoverage: route.scores.parakeet,
            whisperCoverage: route.scores.whisper,
            qwenVote: route.engineVoteScores.qwen,
            parakeetVote: route.engineVoteScores.parakeet,
            whisperVote: route.engineVoteScores.whisper,
            modelID: modelID,
            modelRepository: modelRepository,
            modelRevision: modelRevision,
            generationParameters: generationParameters,
            firstPassRawText: firstPassRawText,
            finalRawText: finalRawText
        )
    }
}
#endif

struct WhisperTuningExperimentOutput: Codable, Sendable {
    let generatedAt: Date
    let modelRepository: String
    let modelRevision: String
    let languageHint: String?
    let appVADPreprocessing: Bool
    let matrix: [WhisperASRTuningProfile]
    let sessions: [WhisperTuningSession]
    let runs: [WhisperTuningRun]
}

enum WhisperTuningTextMetricsCalculator {
    static func calculate(reference: String, candidate: String) -> WhisperTuningTextMetrics {
        let referenceTokens = tokenize(reference)
        let candidateTokens = tokenize(candidate)
        let distance = editDistance(referenceTokens, candidateTokens)
        let denominator = max(1, referenceTokens.count)
        let errorRate = Double(distance) / Double(denominator)
        let referenceText = referenceTokens.joined(separator: " ")
        let candidateText = candidateTokens.joined(separator: " ")
        let maxLength = max(referenceText.count, candidateText.count, 1)
        let charDistance = editDistance(
            Array(referenceText).map(String.init),
            Array(candidateText).map(String.init)
        )
        let similarity = max(0, 1 - Double(charDistance) / Double(maxLength))
        let lengthRatio = referenceTokens.isEmpty
            ? (candidateTokens.isEmpty ? 1 : .infinity)
            : Double(candidateTokens.count) / Double(referenceTokens.count)
        return WhisperTuningTextMetrics(
            referenceTokenCount: referenceTokens.count,
            candidateTokenCount: candidateTokens.count,
            editDistance: distance,
            tokenErrorRate: errorRate,
            normalizedSimilarity: similarity,
            lengthRatio: lengthRatio
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        let normalized = text
            .lowercased()
            .unicodeScalars
            .map { scalar in
                CharacterSet.punctuationCharacters.contains(scalar)
                    || CharacterSet.symbols.contains(scalar)
                    ? " "
                    : String(scalar)
            }
            .joined()
        let pieces = normalized.split { $0.isWhitespace }.map(String.init)
        if pieces.count > 1 { return pieces }
        return pieces.flatMap { piece in
            let hasCJK = piece.unicodeScalars.contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
            }
            return hasCJK ? piece.map(String.init) : [piece]
        }
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            current.reserveCapacity(rhs.count + 1)
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

enum WhisperTuningExperimentCLI {
    private struct Options {
        var outputDirectory: URL
        var sessionIDs: [UUID] = []
        var profileIDs: [String] = []
        var longDurationSeconds: Double = 600
        var languageHint: String?
        var appVADPreprocessing = false
        var productionEquivalent = false
        var audioPath: String?
        var useCPU = false

        init(arguments: [String]) throws {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let stamp = Self.timestamp(Date())
            outputDirectory = root.appendingPathComponent("artifacts/whisper-tuning-\(stamp)")
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--asr-tuning-experiment":
                    break
                case "--output-dir":
                    index += 1
                    outputDirectory = URL(fileURLWithPath: try Self.value(arguments, index))
                case "--session":
                    index += 1
                    guard let id = UUID(uuidString: try Self.value(arguments, index)) else {
                        throw CLIError.invalid("--session")
                    }
                    sessionIDs.append(id)
                case "--profile", "--profiles":
                    index += 1
                    profileIDs.append(contentsOf: try Self.value(arguments, index).split(separator: ",").map(String.init))
                case "--long-seconds":
                    index += 1
                    guard let value = Double(try Self.value(arguments, index)), value > 0 else {
                        throw CLIError.invalid("--long-seconds")
                    }
                    longDurationSeconds = value
                case "--language-hint":
                    index += 1
                    languageHint = try Self.value(arguments, index)
                case "--app-vad":
                    appVADPreprocessing = true
                case "--production-equivalent":
                    productionEquivalent = true
                case "--audio-path":
                    index += 1
                    audioPath = try Self.value(arguments, index)
                case "--cpu":
                    useCPU = true
                case "--help", "-h":
                    throw CLIError.help
                default:
                    throw CLIError.invalid(arguments[index])
                }
                index += 1
            }
        }

        private static func value(_ arguments: [String], _ index: Int) throws -> String {
            guard arguments.indices.contains(index), !arguments[index].isEmpty else {
                throw CLIError.invalid("missing value")
            }
            return arguments[index]
        }

        private static func timestamp(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        }
    }

    private enum CLIError: Error {
        case help
        case invalid(String)
    }

    static func run(arguments: [String]) async -> Int {
        do {
            let options = try Options(arguments: arguments)
            return await execute(options)
        } catch CLIError.help {
            print(usage)
            return 0
        } catch CLIError.invalid(let value) {
            fputs("Invalid ASR tuning argument: \(value)\n\(usage)", stderr)
            return 2
        } catch {
            fputs("ASR tuning experiment failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static let usage = """
    Usage: VoxStudio --asr-tuning-experiment [options]
      --output-dir <path>       Output directory for results.json and report.md
      --session <uuid>          Repeatable; defaults to readable sessions across engines and durations
      --profiles <ids>          Comma-separated profile ids; defaults to the full matrix
      --long-seconds <seconds>  Clip long sessions to this duration; default 600
      --language-hint <code>    Optional decoder language hint; omit for automatic detection
      --app-vad                 Run the app's Silero VAD + SpeechAdmission pre-processing before Whisper
      --production-equivalent   Replay the production ASR path and emit a detailed Whisper trace
      --audio-path <path>       Run the selected tuning profile on an arbitrary audio file
      --cpu                     Run direct audio replay on MLX CPU (useful in headless shells)
    """

    private static func execute(_ options: Options) async -> Int {
        if let audioPath = options.audioPath {
            return await executeDirectAudio(options, sourceURL: URL(fileURLWithPath: audioPath))
        }
        if options.productionEquivalent {
            return await executeProductionEquivalent(options)
        }
        do {
            let snapshotURL = AppSupportPaths.applicationSupport().appendingPathComponent("workbench.json")
            let snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(contentsOf: snapshotURL))
            let profiles = try selectedProfiles(options.profileIDs)
            let sessions = try await selectedSessions(
                from: snapshot.transcriptions,
                requestedIDs: options.sessionIDs,
                longDurationSeconds: options.longDurationSeconds
            )
            guard !sessions.isEmpty else {
                throw NSError(domain: "WhisperTuning", code: 1, userInfo: [NSLocalizedDescriptionKey: "No readable completed sessions were found."])
            }

            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            print("ASR tuning sessions=\(sessions.count) profiles=\(profiles.count) long_clip=\(String(format: "%.1f", options.longDurationSeconds))s app_vad=\(options.appVADPreprocessing)")
            var runs: [WhisperTuningRun] = []
            for session in sessions {
                for profile in profiles {
                    print("RUN session=\(session.title) profile=\(profile.id) range=\(String(format: "%.1f", session.evaluatedEndSeconds))s")
                    let run: WhisperTuningRun
                    do {
                        let decode = try await LocalSpeechPipeline.shared.transcribeWhisperForTuning(
                            sourceURL: URL(fileURLWithPath: session.sourcePath),
                            languageCode: options.languageHint,
                            clipRangeSeconds: session.evaluatedStartSeconds...session.evaluatedEndSeconds,
                            profile: profile,
                            appVADPreprocessing: options.appVADPreprocessing
                        )
                        let metrics = WhisperTuningTextMetricsCalculator.calculate(
                            reference: session.referenceText,
                            candidate: decode.text
                        )
                        run = WhisperTuningRun(session: session, profile: profile, decode: decode, textMetrics: metrics, error: nil)
                        let vadSummary = decode.vadEnabled
                            ? " vadAccepted=\(String(format: "%.3f", decode.vadAcceptedDurationSeconds))s vadElapsed=\(String(format: "%.3f", decode.vadElapsedSeconds))s"
                            : ""
                        print("DONE session=\(session.title) profile=\(profile.id) rtf=\(String(format: "%.4f", decode.realTimeFactor)) similarity=\(String(format: "%.4f", metrics.normalizedSimilarity)) tokens=\(decode.generationTokens)\(vadSummary)")
                    } catch {
                        run = WhisperTuningRun(session: session, profile: profile, decode: nil, textMetrics: nil, error: error.localizedDescription)
                        print("FAIL session=\(session.title) profile=\(profile.id) error=\(error.localizedDescription)")
                    }
                    runs.append(run)
                }
            }
            let repository = LocalModelManager.catalog.first(where: { $0.id == .whisperLargeV3Turbo8Bit })
            let output = WhisperTuningExperimentOutput(
                generatedAt: Date(),
                modelRepository: repository?.repository ?? "mlx-community/whisper-large-v3-turbo-asr-8bit",
                modelRevision: repository?.revision ?? "unknown",
                languageHint: options.languageHint,
                appVADPreprocessing: options.appVADPreprocessing,
                matrix: profiles,
                sessions: sessions,
                runs: runs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(output).write(to: options.outputDirectory.appendingPathComponent("results.json"), options: .atomic)
            try ReportWriter.write(output, to: options.outputDirectory.appendingPathComponent("report.md"))
            print("RESULTS \(options.outputDirectory.path)")
            return runs.contains(where: { $0.error == nil }) ? 0 : 1
        } catch {
            fputs("ASR tuning experiment failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func executeProductionEquivalent(_ options: Options) async -> Int {
        do {
            let snapshotURL = AppSupportPaths.applicationSupport().appendingPathComponent("workbench.json")
            let snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(contentsOf: snapshotURL))
            let sessions = try await selectedSessions(
                from: snapshot.transcriptions,
                requestedIDs: options.sessionIDs,
                longDurationSeconds: options.longDurationSeconds
            )
            guard !sessions.isEmpty else {
                throw NSError(
                    domain: "WhisperProductionReplay",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No readable completed sessions were found."]
                )
            }

            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            print("PRODUCTION_REPLAY sessions=\(sessions.count) language_hint=\(options.languageHint ?? "auto")")
            var runs: [WhisperProductionReplayRun] = []
            for session in sessions {
                print("REPLAY session=\(session.title) source=\(session.sourcePath)")
                do {
                    // A production job with no explicit clip uses the source URL
                    // directly. Preserve that behavior for full-session replays.
                    let clipRange: ClosedRange<Double>? =
                        session.evaluatedStartSeconds == 0
                            && session.evaluatedEndSeconds >= session.sourceDurationSeconds - 0.01
                        ? nil
                        : session.evaluatedStartSeconds...session.evaluatedEndSeconds
                    let replay = try await LocalSpeechPipeline.shared.transcribeWhisperProductionReplay(
                        sourceURL: URL(fileURLWithPath: session.sourcePath),
                        languageCode: options.languageHint,
                        speakerCount: 1,
                        clipRangeSeconds: clipRange
                    )
                    print(
                        "DONE session=\(session.title) engine=\(replay.routeEngine.rawValue) "
                            + "reason=\(replay.routeReason) chunks=\(replay.chunks.count) "
                            + "raw=\(replay.finalRawText ?? "")"
                    )
                    runs.append(.init(session: session, replay: replay, error: nil))
                } catch {
                    print("FAIL session=\(session.title) error=\(error.localizedDescription)")
                    runs.append(.init(session: session, replay: nil, error: error.localizedDescription))
                }
            }

            let output = WhisperProductionReplayOutput(
                generatedAt: Date(),
                languageHint: options.languageHint,
                runs: runs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(output).write(
                to: options.outputDirectory.appendingPathComponent("results.json"),
                options: .atomic
            )
            try ProductionReplayReportWriter.write(
                output,
                to: options.outputDirectory.appendingPathComponent("report.md")
            )
            print("RESULTS \(options.outputDirectory.path)")
            return runs.contains(where: { $0.replay != nil }) ? 0 : 1
        } catch {
            fputs("Production replay failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func executeDirectAudio(_ options: Options, sourceURL: URL) async -> Int {
        do {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw NSError(
                    domain: "WhisperTuning",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Audio file does not exist: \(sourceURL.path)"]
                )
            }
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw NSError(
                    domain: "WhisperTuning",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Audio file has no usable duration: \(sourceURL.path)"]
                )
            }
            let profiles = try selectedProfiles(options.profileIDs.isEmpty ? ["p1_modal_balanced_proxy"] : options.profileIDs)
            guard let profile = profiles.first else {
                throw NSError(
                    domain: "WhisperTuning",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No tuning profile selected."]
                )
            }
            print(
                "DIRECT_AUDIO source=\(sourceURL.path) duration=\(String(format: "%.3f", duration))s "
                    + "profile=\(profile.id) language_hint=\(options.languageHint ?? "auto") "
                    + "app_vad=\(options.appVADPreprocessing)"
            )
            let decode: WhisperTuningDecodeStats
            if options.useCPU {
                decode = try await Device.withDefaultDevice(.cpu) {
                    try await Stream.withNewDefaultStream(device: .cpu) {
                        try await LocalSpeechPipeline.shared.transcribeWhisperForTuning(
                            sourceURL: sourceURL,
                            languageCode: options.languageHint,
                            clipRangeSeconds: nil,
                            profile: profile,
                            appVADPreprocessing: options.appVADPreprocessing
                        )
                    }
                }
            } else {
                decode = try await LocalSpeechPipeline.shared.transcribeWhisperForTuning(
                    sourceURL: sourceURL,
                    languageCode: options.languageHint,
                    clipRangeSeconds: nil,
                    profile: profile,
                    appVADPreprocessing: options.appVADPreprocessing
                )
            }
            print("DIRECT_AUDIO_RESULT text=\(decode.text)")
            print(
                "DIRECT_AUDIO_METRICS rtf=\(String(format: "%.4f", decode.realTimeFactor)) "
                    + "tokens=\(decode.generationTokens)"
            )
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
            let result = [
                "source=\(sourceURL.path)",
                "duration_seconds=\(String(format: "%.6f", duration))",
                "profile=\(profile.id)",
                "language_hint=\(options.languageHint ?? "auto")",
                "cpu=\(options.useCPU)",
                "text=\(decode.text)",
                "rtf=\(String(format: "%.6f", decode.realTimeFactor))",
                "generation_tokens=\(decode.generationTokens)"
            ].joined(separator: "\n") + "\n"
            try result.write(
                to: options.outputDirectory.appendingPathComponent("direct-result.txt"),
                atomically: true,
                encoding: .utf8
            )
            return 0
        } catch {
            fputs("Direct audio ASR failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func selectedProfiles(_ ids: [String]) throws -> [WhisperASRTuningProfile] {
        guard !ids.isEmpty else { return WhisperASRTuningProfile.matrix }
        let byID = Dictionary(uniqueKeysWithValues: WhisperASRTuningProfile.matrix.map { ($0.id, $0) })
        let selected = ids.compactMap { byID[$0] }
        guard selected.count == ids.count else {
            let unknown = ids.filter { byID[$0] == nil }.joined(separator: ", ")
            throw NSError(domain: "WhisperTuning", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown profile id(s): \(unknown)"])
        }
        return selected
    }

    private static func selectedSessions(
        from jobs: [WorkbenchTranscriptionJob],
        requestedIDs: [UUID],
        longDurationSeconds: Double
    ) async throws -> [WhisperTuningSession] {
        var readable: [(WorkbenchTranscriptionJob, Double)] = []
        for job in jobs {
            guard job.state == .completed,
                  job.result != nil,
                  FileManager.default.fileExists(atPath: job.sourceURL.path) else { continue }
            let asset = AVURLAsset(url: job.sourceURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { continue }
            readable.append((job, duration))
        }
        let picked: [(WorkbenchTranscriptionJob, Double)]
        if requestedIDs.isEmpty {
            let shortPool = readable.filter { $0.1 <= 30 }
            let mediumPool = readable.filter { $0.1 > 30 && $0.1 <= 120 }
            let longPool = readable.filter { $0.1 >= longDurationSeconds }
            let whisperMediumPool = mediumPool.filter { $0.0.result?.asrEngine == .whisper }
            let nonWhisperLongPool = longPool.filter { $0.0.result?.asrEngine != .whisper }
            let whisperLongPool = longPool.filter { $0.0.result?.asrEngine == .whisper }
            var candidates: [(WorkbenchTranscriptionJob, Double)] = []
            if let candidate = shortPool.max(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            if let candidate = mediumPool.min(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            if let candidate = whisperMediumPool.max(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            if let candidate = nonWhisperLongPool.min(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            if let candidate = whisperLongPool.max(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            if let candidate = readable.max(by: { $0.1 < $1.1 }) { candidates.append(candidate) }
            var seen = Set<UUID>()
            picked = candidates.filter { seen.insert($0.0.id).inserted }
        } else {
            picked = requestedIDs.compactMap { id in readable.first { $0.0.id == id } }
            guard picked.count == requestedIDs.count else {
                throw NSError(domain: "WhisperTuning", code: 3, userInfo: [NSLocalizedDescriptionKey: "One or more requested sessions are not readable completed sessions."])
            }
        }
        return picked.map { job, duration in
            let end = min(duration, max(1, duration > longDurationSeconds ? longDurationSeconds : duration))
            let reference = referenceText(job.result, start: 0, end: end)
            return WhisperTuningSession(
                sessionID: job.id,
                title: job.sessionTitle,
                sourcePath: job.sourceURL.path,
                sourceDurationSeconds: duration,
                evaluatedStartSeconds: 0,
                evaluatedEndSeconds: end,
                sourceASREngine: job.result?.asrEngine?.rawValue,
                sourceLanguage: job.result?.language ?? job.languageCode,
                referenceText: reference
            )
        }
    }

    private static func referenceText(_ result: TranscriptionResult?, start: Double, end: Double) -> String {
        guard let result else { return "" }
        let selected = result.segments.filter { $0.end > start && $0.start < end }.map(\.text)
        return selected.isEmpty ? result.text : selected.joined(separator: " ")
    }

    private static func sessionLanguage(for reference: String) -> String? {
        let hasCJK = reference.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        return hasCJK ? "zh" : "en"
    }
}

private enum ProductionReplayReportWriter {
    static func write(_ output: WhisperProductionReplayOutput, to URL: URL) throws {
        var lines: [String] = []
        lines.append("# Whisper production-equivalent replay")
        lines.append("")
        lines.append("- generatedAt: `\(ISO8601DateFormatter().string(from: output.generatedAt))`")
        lines.append("- language hint: `\(output.languageHint ?? "auto")`")
        lines.append("- 说明：replay 直接调用当前 `processSpeech`，不写回 Workbench；`finalRawText` 是生产 ASR/对齐前的最终文本。")
        lines.append("")

        for run in output.runs {
            lines.append("## \(run.session.title)")
            lines.append("")
            lines.append("- source: `\(run.session.sourcePath)`")
            guard let replay = run.replay else {
                lines.append("- error: `\(run.error ?? "unknown")`")
                lines.append("")
                continue
            }
            lines.append("- clip: `\(format(replay.clipStartSeconds))–\(format(replay.clipEndSeconds))s`")
            lines.append("- audio samples: decoded `\(replay.decodedSampleCount)`, prepared `\(replay.preparedSampleCount)` (`\(format(replay.decodedDurationSeconds))s`)")
            lines.append("- audio level: RMS `\(format(replay.originalRMSDBFS)) → \(format(replay.processedRMSDBFS)) dBFS`, peak `\(format(replay.originalPeakDBFS)) → \(format(replay.processedPeakDBFS)) dBFS`, rescue `\(format(replay.rescueGainDB)) dB`")
            lines.append("- ranges: VAD accepted `\(ranges(replay.vadAcceptedRanges))`; scene-veto output `\(ranges(replay.sceneVetoedRanges))`; final allowed `\(ranges(replay.finalAllowedSpeechRanges))`")
            lines.append("- route: `\(replay.routeEngine.rawValue)` / reason `\(replay.routeReason)` / top `\(replay.routeTopLanguage ?? "nil")` / hint `\(replay.whisperHint ?? "nil")` / prompt `\(replay.languagePrompt ?? "nil")`")
            lines.append("- model: `\(replay.modelID)` `\(replay.modelRepository)` revision `\(replay.modelRevision)`")
            let parameters = replay.generationParameters
            lines.append("- parameters: maxTokens `\(parameters.maxTokens)`, temperature `\(parameters.temperature)`, topP `\(parameters.topP)`, topK `\(parameters.topK)`, repetition `\(parameters.repetitionPenalty)`, context `\(parameters.repetitionContextSize)`, chunkDuration `\(parameters.chunkDuration)`, minChunkDuration `\(parameters.minChunkDuration)`, kvBits `\(parameters.kvBits.map(String.init) ?? "nil")`")
            lines.append("- first-pass raw text: `\(replay.firstPassRawText ?? "")`")
            lines.append("- final raw text: `\(replay.finalRawText ?? "")`")
            lines.append("")
            lines.append("### Whisper chunks")
            lines.append("")
            lines.append("| # | input | ownership | samples | prompt | generated | text | elapsed |")
            lines.append("|---:|---:|---:|---:|---:|---:|---|---:|")
            for chunk in replay.chunks {
                let text = chunk.text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
                lines.append("| \(chunk.index) | \(format(chunk.inputStart))–\(format(chunk.inputEnd)) | \(format(chunk.ownershipStart))–\(format(chunk.ownershipEnd)) | \(chunk.inputSampleCount) | \(chunk.promptTokens) | \(chunk.generationTokens) | \(text) | \(format(chunk.elapsedSeconds))s |")
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: URL, atomically: true, encoding: .utf8)
    }

    private static func ranges(_ values: [ASRSpeechRange]) -> String {
        values.map { "\(format($0.start))–\(format($0.end))s" }.joined(separator: ", ")
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4f", value) : "∞"
    }
}

private enum ReportWriter {
    static func write(_ output: WhisperTuningExperimentOutput, to URL: URL) throws {
        var lines: [String] = []
        lines.append("# Whisper Large-v3 Turbo MLX 参数调优实验")
        lines.append("")
        lines.append("- 生成时间：\(ISO8601DateFormatter().string(from: output.generatedAt))")
        lines.append("- 模型：`\(output.modelRepository)`")
        lines.append("- revision：`\(output.modelRevision)`")
        lines.append("- language hint：`\(output.languageHint ?? "未传（自动检测）")`")
        lines.append("- app VAD 前置：`\(output.appVADPreprocessing ? "启用（Silero CoreML + SpeechAdmission.standard）" : "未启用")`")
        lines.append("- 评估口径：当前 app session 已保存 transcript 作为弱参考；这不是人工 ground truth，因此 similarity/token error 只能用于回归一致性，不等同于真实 WER。")
        lines.append("- 参考实现：[mlx-community Whisper Large-v3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo/blob/main/README.md)、[mlx-whisper decoder](https://github.com/ml-explore/mlx-examples/blob/main/whisper/mlx_whisper/transcribe.py)、[mlx-audio Whisper fallback](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/whisper/whisper.py)。")
        lines.append("")
        lines.append("## 参数矩阵")
        lines.append("")
        lines.append("| ID | 配置 | temperature | top-p | top-k | repetition penalty | context |")
        lines.append("|---|---|---:|---:|---:|---:|---:|")
        for profile in output.matrix {
            lines.append("| \(profile.id) | \(profile.label) | \(profile.temperature) | \(profile.topP) | \(profile.topK) | \(profile.repetitionPenalty) | \(profile.repetitionContextSize) |")
        }
        lines.append("")
        lines.append("## Modal / 社区 MLX 参数映射")
        lines.append("")
        lines.append("| 参数语义 | Modal / faster-whisper 参考 | 本地 MLX Whisper 实现 | 本实验处理 |")
        lines.append("|---|---|---|---|")
        lines.append("| 搜索/采样 | `beam_size=3`（中文可用 5）、`best_of=1`、`temperature=[0,.2,.4,.6,.8,1]` | 无 beam/best-of；支持 greedy 与本实验新增的 top-k/top-p | 以 p0/p1/p2/p5 做 greedy，p3/p4 做低温 sampling |")
        lines.append("| 重复控制 | `repetition_penalty=1.1`、`no_repeat_ngram_size=3` | 支持 `repetitionPenalty` + 最近 token context；无 n-gram 禁止 | 1.05/1.10 × context 32/64 |")
        lines.append("| 质量回退 | `compression_ratio_threshold=2.0`、`log_prob_threshold=-0.7`、`no_speech_threshold=.45`、`hallucination_silence_threshold=.8` | 当前 generate API 无对应置信度/回退输出 | 保留为后续 API 扩展项，不虚构实验效果 |")
        lines.append("| VAD 前置 | app Silero VAD + `SpeechAdmission.standard`（entry `.60`、exit `.45`、最短语音 `.50s`、最短静音 `.50s`） | 复用 `SpeechAnalysisService` 与 `SpeechAdmission`，再按接受区间调用 Whisper | 由 `--app-vad` 开启；否则保持 raw 全片 decoder baseline |")
        lines.append("| 音频切分 | VAD onset `.5`、offset `.363`，chunk 30s | app 音频 decode + gain rescue；Whisper decoder 固定 30s window | 所有 profile 使用同一音频输入与 window |")
        lines.append("")
        lines.append("## Session 覆盖")
        lines.append("")
        lines.append("| Session | 历史引擎 | 源时长 | 评估区间 | 参考 token 数 |")
        lines.append("|---|---|---:|---:|---:|")
        for session in output.sessions {
            let referenceCount = WhisperTuningTextMetricsCalculator.calculate(reference: session.referenceText, candidate: session.referenceText).referenceTokenCount
            let sourceEngine = session.sourceASREngine ?? "unknown"
            lines.append("| \(session.title.replacingOccurrences(of: "|", with: "\\|")) | \(sourceEngine) | \(format(session.sourceDurationSeconds))s | 0–\(format(session.evaluatedEndSeconds))s | \(referenceCount) |")
        }
        lines.append("")
        lines.append("## 结果汇总")
        lines.append("")
        lines.append("| Session | 配置 | RTF ↓ | 生成 token | similarity ↑ | token error ↓ | 长度比 | VAD speech | VAD elapsed |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")
        for run in output.runs {
            guard let decode = run.decode, let metrics = run.textMetrics else {
                lines.append("| \(run.session.title) | \(run.profile.id) | — | — | — | — | — | — | error: \(run.error ?? "unknown") |")
                continue
            }
            let vadSpeech = decode.vadEnabled ? "\(format(decode.vadAcceptedDurationSeconds))s" : "—"
            let vadElapsed = decode.vadEnabled ? "\(format(decode.vadElapsedSeconds))s" : "—"
            lines.append("| \(run.session.title) | \(run.profile.id) | \(format(decode.realTimeFactor)) | \(decode.generationTokens) | \(format(metrics.normalizedSimilarity)) | \(format(metrics.tokenErrorRate)) | \(format(metrics.lengthRatio)) | \(vadSpeech) | \(vadElapsed) |")
        }
        lines.append("")
        lines.append("## 配置聚合")
        lines.append("")
        lines.append("| 配置 | 成功数 | 平均 RTF ↓ | 平均 similarity ↑ | 平均 token error ↓ |")
        lines.append("|---|---:|---:|---:|---:|")
        for profile in output.matrix {
            let successful = output.runs.filter { $0.profile.id == profile.id }.compactMap { run -> (rtf: Double, similarity: Double, editDistance: Int, referenceTokens: Int, elapsed: Double, audio: Double)? in
                guard let decode = run.decode, let metrics = run.textMetrics else { return nil }
                return (
                    rtf: decode.realTimeFactor,
                    similarity: metrics.normalizedSimilarity,
                    editDistance: metrics.editDistance,
                    referenceTokens: metrics.referenceTokenCount,
                    elapsed: decode.elapsedSeconds,
                    audio: run.session.evaluatedEndSeconds - run.session.evaluatedStartSeconds
                )
            }
            let totalReferenceTokens = successful.reduce(0) { $0 + $1.referenceTokens }
            let totalAudio = successful.reduce(0) { $0 + $1.audio }
            let totalElapsed = successful.reduce(0) { $0 + $1.elapsed }
            let referenceDenominator = Double(max(totalReferenceTokens, 1))
            let weightedSimilarity = successful.reduce(0) {
                $0 + $1.similarity * Double($1.referenceTokens)
            } / referenceDenominator
            let weightedError = Double(successful.reduce(0) { $0 + $1.editDistance }) / referenceDenominator
            let aggregateRTF = totalElapsed / max(totalAudio, 0.001)
            lines.append("| \(profile.id) | \(successful.count) | \(format(aggregateRTF)) | \(format(weightedSimilarity)) | \(format(weightedError)) |")
        }
        lines.append("")
        lines.append("## 解读")
        lines.append("")
        lines.append("- `temperature=0` 是可复现的 greedy 主线；`temperature>0` 的两组用于验证社区常见 top-p/top-k sampling 是否改善当前 session 的长段落一致性，但它们不是 Modal 的多温度 fallback 的一比一实现。")
        lines.append("- Modal 的 `beam_size/best_of/compression_ratio_threshold/log_prob_threshold/no_speech_threshold/condition_on_previous_text` 在当前本地 MLX Whisper API 中没有等价入口；本实验没有伪造这些字段的效果。")
        let maxEvaluatedSeconds = output.sessions.map(\.evaluatedEndSeconds).max() ?? 0
        lines.append("- session 选择覆盖所有可读 completed session 的分层抽样：≤30s 短样本、30–120s 中样本、历史 Whisper 中样本、非 Whisper 长样本和历史 Whisper 长样本；每个长样本最多评估前 \(format(maxEvaluatedSeconds))s。")
        lines.append("- 结果以 `results.json` 保存，包含每次候选全文，可继续做人工 spot-check 或换成人工 reference 重算 WER。")
        try lines.joined(separator: "\n").write(to: URL, atomically: true, encoding: .utf8)
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4f", value) : "∞"
    }
}
#endif
