import CoreML
import FluidAudio
import Foundation
import MLX
import MLXAudioCore
import MLXAudioVAD

@main
struct VADRTFReplay {
    static func main() async {
        do {
            try await Task.detached { try await run() }.value
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            throw fail(
                "Usage: VADRTFReplay AUDIO_PATH [SECONDS] [OUTPUT_JSON]\n"
                    + "Env: VOXELLA_SILERO_MLX_DIR VOXELLA_SILERO_COREML_DIR "
                    + "VOXELLA_VAD_BACKENDS=coreml-cpu,mlx-full,mlx-chunked VOXELLA_VAD_WARMUP_SECONDS"
            )
        }

        let audioURL = URL(fileURLWithPath: args[1])
        let requestedSeconds: Double? = args.count >= 3 ? Double(args[2]) : nil
        if let requestedSeconds, !(requestedSeconds > 0 && requestedSeconds <= 7200) {
            throw fail("SECONDS must be in (0, 7200]")
        }
        let outputURL = args.count >= 4
            ? URL(fileURLWithPath: args[3])
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("results.json")

        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech/models", isDirectory: true)
        let mlxDir = URL(
            fileURLWithPath: env["VOXELLA_SILERO_MLX_DIR"]
                ?? cacheRoot.appendingPathComponent("mlx-community/silero-vad-v6").path,
            isDirectory: true
        )
        let coreMLDir = URL(
            fileURLWithPath: env["VOXELLA_SILERO_COREML_DIR"]
                ?? cacheRoot.appendingPathComponent("FluidInference/silero-vad-coreml").path,
            isDirectory: true
        )
        let warmupSeconds = Double(env["VOXELLA_VAD_WARMUP_SECONDS"] ?? "5") ?? 5
        let backends = (env["VOXELLA_VAD_BACKENDS"] ?? "coreml-cpu,mlx-full,mlx-chunked")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        log("decode path=\(audioURL.path)")
        let decodeStarted = ContinuousClock.now
        let (rate, loaded) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
        var audio = loaded.ndim > 1 ? mean(loaded, axis: -1) : loaded
        eval(audio)
        let availableSeconds = Double(audio.dim(0)) / Double(rate)
        let limitSeconds = requestedSeconds.map { min($0, availableSeconds) } ?? availableSeconds
        let sampleCount = min(audio.dim(0), Int((limitSeconds * Double(rate)).rounded(.down)))
        audio = audio[..<sampleCount]
        eval(audio)
        let samples = audio.asArray(Float.self)
        let audioSeconds = Double(sampleCount) / Double(rate)
        let warmupCount = min(sampleCount, max(rate, Int((warmupSeconds * Double(rate)).rounded(.down))))
        log(
            "decoded samples=\(sampleCount) seconds=\(fmt(audioSeconds, 3)) "
                + "decode_s=\(fmt(elapsed(decodeStarted), 3)) rate=\(rate)"
        )

        var mlxModel: SileroVAD?
        var coreMLManager: VadManager?
        if backends.contains(where: { $0.hasPrefix("mlx-") }) {
            let loadStarted = ContinuousClock.now
            mlxModel = try SileroVAD.fromModelDirectory(mlxDir)
            log("mlx model ready elapsed=\(fmt(elapsed(loadStarted), 3))s dir=\(mlxDir.path)")
        }
        if backends.contains("coreml-cpu") {
            let loadStarted = ContinuousClock.now
            let bundle = coreMLDir.appendingPathComponent(
                "silero-vad-unified-256ms-v6.2.1.mlmodelc",
                isDirectory: true
            )
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try await MLModel.load(contentsOf: bundle, configuration: configuration)
            coreMLManager = VadManager(
                config: VadConfig(defaultThreshold: 0.5, computeUnits: .cpuOnly),
                vadModel: model
            )
            log("coreml model ready elapsed=\(fmt(elapsed(loadStarted), 3))s dir=\(bundle.path)")
        }

        var runs: [RunResult] = []
        var mlxChunked: [Float]?
        var mlxFull: [Float]?
        for backend in backends {
            Memory.clearCache()
            let warmupAudio = audio[..<warmupCount]
            let warmupSamples = Array(samples.prefix(warmupCount))
            log("warmup backend=\(backend) seconds=\(fmt(Double(warmupCount) / Double(rate), 3))")
            switch backend {
            case "coreml-cpu":
                guard let coreMLManager else { throw fail("Core ML model missing") }
                _ = try await inferCoreML(manager: coreMLManager, samples: warmupSamples)
            case "mlx-full":
                guard let mlxModel else { throw fail("MLX model missing") }
                _ = try inferMLXFull(model: mlxModel, audio: warmupAudio)
            case "mlx-chunked":
                guard let mlxModel else { throw fail("MLX model missing") }
                _ = try inferMLXChunked(model: mlxModel, audio: warmupAudio)
            default:
                throw fail("Unknown backend \(backend)")
            }

            log("timed backend=\(backend) seconds=\(fmt(audioSeconds, 3))")
            let started = ContinuousClock.now
            let peakBefore = Memory.peakMemory
            let values: [Float]
            let hopSeconds: Double
            switch backend {
            case "coreml-cpu":
                guard let coreMLManager else { throw fail("Core ML model missing") }
                values = try await inferCoreML(manager: coreMLManager, samples: samples)
                hopSeconds = 4096.0 / 16_000.0
            case "mlx-full":
                guard let mlxModel else { throw fail("MLX model missing") }
                values = try inferMLXFull(model: mlxModel, audio: audio)
                mlxFull = values
                hopSeconds = 512.0 / 16_000.0
            case "mlx-chunked":
                guard let mlxModel else { throw fail("MLX model missing") }
                values = try inferMLXChunked(model: mlxModel, audio: audio)
                mlxChunked = values
                hopSeconds = 512.0 / 16_000.0
            default:
                throw fail("Unknown backend \(backend)")
            }
            let elapsedSeconds = elapsed(started)
            let rtf = elapsedSeconds / max(audioSeconds, 0.001)
            let speechSeconds = Double(values.filter { $0 >= 0.5 }.count) * hopSeconds
            let run = RunResult(
                id: backend,
                elapsedSeconds: elapsedSeconds,
                rtf: rtf,
                frames: values.count,
                hopSeconds: hopSeconds,
                speechSeconds: speechSeconds,
                speechRatio: speechSeconds / max(audioSeconds, 0.001),
                meanProbability: Double(values.reduce(0, +)) / Double(max(values.count, 1)),
                mlxPeakBytes: Memory.peakMemory,
                mlxPeakDeltaBytes: max(0, Memory.peakMemory - peakBefore),
                meetsCommunityTarget: rtf <= 0.003,
                meetsFluidAudioTarget: rtf <= 0.001
            )
            runs.append(run)
            log(
                "complete backend=\(backend) elapsed=\(fmt(elapsedSeconds, 4))s "
                    + "rtf=\(fmt(rtf, 5)) frames=\(values.count) "
                    + "speech_s=\(fmt(speechSeconds, 2)) community=\(run.meetsCommunityTarget) "
                    + "fluidaudio=\(run.meetsFluidAudioTarget)"
            )
        }

        var maxAbsDelta: Double?
        if let mlxChunked, let mlxFull, mlxChunked.count == mlxFull.count {
            var peak: Float = 0
            for (a, b) in zip(mlxChunked, mlxFull) {
                peak = max(peak, abs(a - b))
            }
            maxAbsDelta = Double(peak)
            log("mlx-full vs mlx-chunked max|Δ|=\(fmt(maxAbsDelta ?? 0, 5)) frames=\(mlxChunked.count)")
        } else if mlxChunked != nil, mlxFull != nil {
            log("mlx-full vs mlx-chunked frame-count mismatch")
        }

        let payload = ExperimentResult(
            audioPath: audioURL.path,
            audioSeconds: audioSeconds,
            sampleRate: rate,
            warmupSeconds: warmupSeconds,
            communityRTFTarget: 0.003,
            fluidAudioRTFTarget: 0.001,
            mlxChunkedVsFullMaxAbsDelta: maxAbsDelta,
            runs: runs
        )
        let data = try JSONEncoder.pretty.encode(payload)
        try data.write(to: outputURL)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        log("wrote \(outputURL.path)")
    }

    private static func inferMLXChunked(model: SileroVAD, audio: MLXArray) throws -> [Float] {
        let output = try model.predictProba(audio, sampleRate: 16_000)
        eval(output)
        let values = output.asArray(Float.self)
        guard values.allSatisfy(\.isFinite) else { throw fail("mlx-chunked produced non-finite probabilities") }
        return values
    }

    private static func inferMLXFull(model: SileroVAD, audio: MLXArray) throws -> [Float] {
        let output = try model.predictProbaFullSequence(audio, sampleRate: 16_000)
        eval(output)
        let values = output.asArray(Float.self)
        guard values.allSatisfy(\.isFinite) else { throw fail("mlx-full produced non-finite probabilities") }
        return values
    }

    private static func inferCoreML(manager: VadManager, samples: [Float]) async throws -> [Float] {
        let results = try await manager.process(samples)
        let values = results.map(\.probability)
        guard values.allSatisfy(\.isFinite) else { throw fail("coreml-cpu produced non-finite probabilities") }
        return values
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "VADRTFReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct RunResult: Codable {
    var id: String
    var elapsedSeconds: Double
    var rtf: Double
    var frames: Int
    var hopSeconds: Double
    var speechSeconds: Double
    var speechRatio: Double
    var meanProbability: Double
    var mlxPeakBytes: Int
    var mlxPeakDeltaBytes: Int
    var meetsCommunityTarget: Bool
    var meetsFluidAudioTarget: Bool
}

private struct ExperimentResult: Codable {
    var audioPath: String
    var audioSeconds: Double
    var sampleRate: Int
    var warmupSeconds: Double
    var communityRTFTarget: Double
    var fluidAudioRTFTarget: Double
    var mlxChunkedVsFullMaxAbsDelta: Double?
    var runs: [RunResult]
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
