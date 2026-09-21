import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTS

@main
struct MossFormerReplay {
    static func main() async throws {
        try await Task.detached {
            let args = try CLI.parse()
            let outDir = URL(fileURLWithPath: args.outDir, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            FileHandle.standardError.write(Data("Loading MossFormer2-SE FP16\n".utf8))
            let moss = try await MossFormer2SEModel.fromPretrained("starkdmi/MossFormer2-SE-fp16")
            guard moss.sampleRate == 48_000 else {
                throw ReplayError.message("Expected 48 kHz MossFormer, got \(moss.sampleRate)")
            }

            let dfn: DeepFilterNetModel?
            if args.needsDeepFilterNet {
                FileHandle.standardError.write(Data("Loading DeepFilterNet v3\n".utf8))
                let loaded = try await DeepFilterNetModel.fromPretrained()
                guard loaded.sampleRate == 48_000 else {
                    throw ReplayError.message("Expected 48 kHz DeepFilterNet, got \(loaded.sampleRate)")
                }
                dfn = loaded
            } else {
                dfn = nil
            }

            let fixtures: [Fixture]
            let recipesByFixture: [String: [Recipe]]
            if !args.audioPaths.isEmpty {
                var loaded: [Fixture] = []
                var recipes: [String: [Recipe]] = [:]
                for audioPath in args.audioPaths {
                    let fixture = try FixtureBuilder.loadFile(
                        URL(fileURLWithPath: audioPath),
                        sampleRate: 48_000
                    )
                    try AudioUtils.writeWavFile(
                        samples: fixture.samples,
                        sampleRate: 48_000,
                        fileURL: outDir.appendingPathComponent("\(fixture.id)__dry.wav")
                    )
                    loaded.append(fixture)
                    recipes[fixture.id] = fixture.durationSec >= 60
                        ? Recipe.mossFormerLong
                        : Recipe.mossFormerReview
                }
                fixtures = loaded
                recipesByFixture = recipes
            } else {
                let mediaDir = URL(fileURLWithPath: args.mediaDir!, isDirectory: true)
                fixtures = try FixtureBuilder.load(mediaDir: mediaDir, sampleRate: 48_000)
                recipesByFixture = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, Recipe.all) })
            }
            try warmup(moss: moss, dfn: dfn)

            var report = Report(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                mossRepo: MossFormer2SEModel.defaultRepo,
                dfnRepo: "\(DeepFilterNetModel.defaultRepo)/\(DeepFilterNetModel.defaultSubfolder)",
                sampleRate: 48_000,
                fixtures: fixtures.map(\.summary),
                runs: []
            )

            var fullRefs: [String: [Float]] = [:]
            var dfnRefs: [String: [Float]] = [:]

            for fixture in fixtures {
                let recipes = recipesByFixture[fixture.id] ?? Recipe.mossFormerReview
                for recipe in recipes {
                    FileHandle.standardError.write(Data("run fixture=\(fixture.id) recipe=\(recipe.id)\n".utf8))
                    Memory.clearCache()
                    Memory.peakMemory = 0
                    let started = ContinuousClock.now
                    let samples: [Float]
                    do {
                        samples = try enhance(
                            audio: fixture.audio,
                            recipe: recipe,
                            moss: moss,
                            dfn: dfn
                        )
                    } catch {
                        let elapsed = seconds(from: started)
                        report.runs.append(
                            RunResult(
                                fixture: fixture.id,
                                recipe: recipe.id,
                                backend: recipe.backend.rawValue,
                                mode: recipe.mode.rawValue,
                                ok: false,
                                error: String(describing: error),
                                elapsedSec: elapsed,
                                rtf: elapsed / max(fixture.durationSec, 1e-6),
                                mlxPeakBytes: Memory.peakMemory,
                                outputSamples: 0,
                                chunkCount: 0,
                                corrVsMossFull: nil,
                                corrVsDfnOffline: nil,
                                siSdrVsTargetDb: nil,
                                residualRmsRatio: nil,
                                spliceJumpRms: nil,
                                finiteSampleRatio: nil,
                                wavPath: nil
                            )
                        )
                        FileHandle.standardError.write(Data("  failed: \(error)\n".utf8))
                        continue
                    }
                    eval(MLXArray(samples))
                    let elapsed = seconds(from: started)
                    if recipe.id == "moss_full" { fullRefs[fixture.id] = samples }
                    if recipe.id == "dfn_offline" { dfnRefs[fixture.id] = samples }

                    let wavURL = outDir.appendingPathComponent("\(fixture.id)__\(recipe.id).wav")
                    try AudioUtils.writeWavFile(samples: samples, sampleRate: 48_000, fileURL: wavURL)

                    let corrFull = fullRefs[fixture.id].map { correlation(samples, $0) }
                    let corrDfn = dfnRefs[fixture.id].map { correlation(samples, $0) }
                    let siSdr = fixture.target.map { siSDR(estimate: samples, reference: $0) }
                    let residual = residualRmsRatio(input: fixture.samples, enhanced: samples)
                    let finiteRatio = finiteSampleRatio(samples)
                    let splice = spliceJumpRMS(
                        samples: samples,
                        sampleRate: 48_000,
                        chunkSeconds: recipe.chunkSeconds,
                        overlapSeconds: recipe.overlapSeconds,
                        overlapRatio: recipe.overlapRatio
                    )

                    report.runs.append(
                        RunResult(
                            fixture: fixture.id,
                            recipe: recipe.id,
                            backend: recipe.backend.rawValue,
                            mode: recipe.mode.rawValue,
                            ok: true,
                            error: nil,
                            elapsedSec: elapsed,
                            rtf: elapsed / max(fixture.durationSec, 1e-6),
                            mlxPeakBytes: Memory.peakMemory,
                            outputSamples: samples.count,
                            chunkCount: recipe.expectedChunkCount(sampleCount: fixture.samples.count, sampleRate: 48_000),
                            corrVsMossFull: finiteOrNil(corrFull),
                            corrVsDfnOffline: finiteOrNil(corrDfn),
                            siSdrVsTargetDb: finiteOrNil(siSdr),
                            residualRmsRatio: finiteOrNil(residual),
                            spliceJumpRms: finiteOrNil(splice),
                            finiteSampleRatio: finiteOrNil(finiteRatio),
                            wavPath: wavURL.path
                        )
                    )
                    FileHandle.standardError.write(
                        Data(
                            String(
                                format: "  elapsed=%.2fs rtf=%.3f peak=%.1fMB corr_full=%@ corr_dfn=%@ finite=%@\n",
                                elapsed,
                                elapsed / max(fixture.durationSec, 1e-6),
                                Double(Memory.peakMemory) / 1_000_000,
                                corrFull.map { String(format: "%.4f", $0) } ?? "-",
                                corrDfn.map { String(format: "%.4f", $0) } ?? "-",
                                String(format: "%.4f", finiteRatio)
                            ).utf8
                        )
                    )
                }
            }

            let jsonURL = outDir.appendingPathComponent("results.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: jsonURL)
            try markdown(for: report).write(to: outDir.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
            print("Wrote \(jsonURL.path)")
        }.value
    }
}

// MARK: - CLI

struct CLI {
    var mediaDir: String?
    var audioPaths: [String]
    var outDir: String

    var needsDeepFilterNet: Bool { audioPaths.isEmpty }

    static func parse() throws -> CLI {
        var mediaDir: String?
        var audioPaths: [String] = []
        var outDir: String?
        var args = CommandLine.arguments.dropFirst()
        while let arg = args.first {
            args = args.dropFirst()
            switch arg {
            case "--media-dir":
                mediaDir = args.first
                args = args.dropFirst()
            case "--audio":
                guard let path = args.first else {
                    throw ReplayError.message("Missing value for --audio")
                }
                audioPaths.append(path)
                args = args.dropFirst()
            case "--out-dir":
                outDir = args.first
                args = args.dropFirst()
            default:
                throw ReplayError.message("Unknown argument \(arg)")
            }
        }
        guard let outDir else {
            throw ReplayError.message("Usage: MossFormerReplay --out-dir DIR (--audio FILE ... | --media-dir DIR)")
        }
        if audioPaths.isEmpty, mediaDir == nil {
            throw ReplayError.message("Usage: MossFormerReplay --out-dir DIR (--audio FILE ... | --media-dir DIR)")
        }
        return CLI(mediaDir: mediaDir, audioPaths: audioPaths, outDir: outDir)
    }
}

enum ReplayError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

// MARK: - Recipes

enum Backend: String, Encodable {
    case mossformer
    case deepfilternet
}

enum Mode: String, Encodable {
    case full
    case segmented
    case chunkedDiscard = "chunked_discard"
    case chunkedOLA = "chunked_ola"
    case dfnOffline = "dfn_offline"
    case dfnStream = "dfn_stream"
}

struct Recipe {
    let id: String
    let backend: Backend
    let mode: Mode
    let chunkSeconds: Float?
    let overlapRatio: Float?
    let overlapSeconds: Float?
    let decodeWindow: Float?

    static let mossFormerReview: [Recipe] = [
        Recipe(id: "moss_full", backend: .mossformer, mode: .full, chunkSeconds: nil, overlapRatio: nil, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "moss_chunked_discard_4s_0.25", backend: .mossformer, mode: .chunkedDiscard, chunkSeconds: 4, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: nil),
    ]

    static let mossFormerLong: [Recipe] = [
        Recipe(id: "moss_chunked_discard_4s_0.25", backend: .mossformer, mode: .chunkedDiscard, chunkSeconds: 4, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: nil),
    ]

    static let all: [Recipe] = [
        Recipe(id: "moss_full", backend: .mossformer, mode: .full, chunkSeconds: nil, overlapRatio: nil, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "moss_segmented_w3", backend: .mossformer, mode: .segmented, chunkSeconds: nil, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: 3),
        Recipe(id: "moss_segmented_w4", backend: .mossformer, mode: .segmented, chunkSeconds: nil, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: 4),
        Recipe(id: "moss_segmented_w6", backend: .mossformer, mode: .segmented, chunkSeconds: nil, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: 6),
        Recipe(id: "moss_chunked_discard_3s_0.25", backend: .mossformer, mode: .chunkedDiscard, chunkSeconds: 3, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "moss_chunked_discard_4s_0.25", backend: .mossformer, mode: .chunkedDiscard, chunkSeconds: 4, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "moss_chunked_discard_6s_0.25", backend: .mossformer, mode: .chunkedDiscard, chunkSeconds: 6, overlapRatio: 0.25, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "moss_chunked_ola_3s_0.25s", backend: .mossformer, mode: .chunkedOLA, chunkSeconds: 3, overlapRatio: nil, overlapSeconds: 0.25, decodeWindow: nil),
        Recipe(id: "moss_chunked_ola_4s_0.50s", backend: .mossformer, mode: .chunkedOLA, chunkSeconds: 4, overlapRatio: nil, overlapSeconds: 0.50, decodeWindow: nil),
        Recipe(id: "moss_chunked_ola_6s_1.00s", backend: .mossformer, mode: .chunkedOLA, chunkSeconds: 6, overlapRatio: nil, overlapSeconds: 1.00, decodeWindow: nil),
        Recipe(id: "dfn_offline", backend: .deepfilternet, mode: .dfnOffline, chunkSeconds: nil, overlapRatio: nil, overlapSeconds: nil, decodeWindow: nil),
        Recipe(id: "dfn_stream_0.48s", backend: .deepfilternet, mode: .dfnStream, chunkSeconds: 0.48, overlapRatio: nil, overlapSeconds: nil, decodeWindow: nil),
    ]

    func expectedChunkCount(sampleCount: Int, sampleRate: Int) -> Int {
        switch mode {
        case .full, .dfnOffline:
            return 1
        case .dfnStream:
            let chunk = max(1, Int(Float(sampleRate) * (chunkSeconds ?? 0.48)))
            return max(1, Int(ceil(Double(sampleCount) / Double(chunk))))
        case .segmented:
            let window = max(1, Int(Float(sampleRate) * (decodeWindow ?? 4)))
            let stride = max(1, Int(Float(window) * 0.75))
            if sampleCount <= window { return 1 }
            return max(1, 1 + (sampleCount - window + stride - 1) / stride)
        case .chunkedDiscard:
            let chunk = max(1, Int(Float(sampleRate) * (chunkSeconds ?? 4)))
            let overlap = Int(Float(chunk) * (overlapRatio ?? 0.25))
            let stride = max(1, chunk - overlap)
            if sampleCount <= chunk { return 1 }
            return 1 + (sampleCount - chunk + stride - 1) / stride
        case .chunkedOLA:
            let chunk = max(1, Int(Float(sampleRate) * (chunkSeconds ?? 4)))
            let overlap = Int(Float(sampleRate) * (overlapSeconds ?? 0.5))
            let stride = max(1, chunk - overlap)
            if sampleCount <= chunk { return 1 }
            return 1 + (sampleCount - 1) / stride
        }
    }
}

// MARK: - Fixtures

struct Fixture {
    let id: String
    let audio: MLXArray
    let samples: [Float]
    let durationSec: Double
    let target: [Float]?

    var summary: FixtureSummary {
        FixtureSummary(
            id: id,
            durationSec: durationSec,
            sampleCount: samples.count,
            hasTarget: target != nil
        )
    }
}

struct FixtureSummary: Encodable {
    let id: String
    let durationSec: Double
    let sampleCount: Int
    let hasTarget: Bool
}

enum FixtureBuilder {
    static func loadFile(_ url: URL, sampleRate: Int) throws -> Fixture {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReplayError.message("Missing audio file: \(url.path)")
        }
        let samples = try loadMonoSamples(from: url, sampleRate: sampleRate)
        return fixture(id: url.deletingPathExtension().lastPathComponent, samples: samples, sampleRate: sampleRate, target: nil)
    }

    static func load(mediaDir: URL, sampleRate: Int) throws -> [Fixture] {
        let names = [
            "noisy_audio.wav",
            "conversational_a.wav",
            "conversational_fr.wav",
            "multi_speaker.wav",
            "intention.wav",
            "false-turn.wav",
        ]
        var sources: [[Float]] = []
        for name in names {
            let url = mediaDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (_, audio) = try loadAudioArray(from: url, sampleRate: sampleRate)
            sources.append(audio.asArray(Float.self))
        }
        guard let shortSamples = sources.first else {
            throw ReplayError.message("Missing noisy_audio.wav in \(mediaDir.path)")
        }

        var target: [Float]?
        let targetURL = mediaDir.appendingPathComponent("noisy_audio_target.wav")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let (_, targetAudio) = try loadAudioArray(from: targetURL, sampleRate: sampleRate)
            target = targetAudio.asArray(Float.self)
        }

        let medium = concatenated(sources, minimumSeconds: 24, sampleRate: sampleRate)
        let long = concatenated(sources, minimumSeconds: 72, sampleRate: sampleRate)
        return [
            fixture(id: "short", samples: shortSamples, sampleRate: sampleRate, target: target),
            fixture(id: "medium", samples: medium, sampleRate: sampleRate, target: nil),
            fixture(id: "long", samples: long, sampleRate: sampleRate, target: nil),
        ]
    }

    private static func concatenated(_ sources: [[Float]], minimumSeconds: Double, sampleRate: Int) -> [Float] {
        let needed = Int(minimumSeconds * Double(sampleRate))
        var out: [Float] = []
        out.reserveCapacity(needed)
        var index = 0
        while out.count < needed {
            out.append(contentsOf: sources[index % sources.count])
            index += 1
        }
        return out
    }

    private static func fixture(id: String, samples: [Float], sampleRate: Int, target: [Float]?) -> Fixture {
        Fixture(
            id: id,
            audio: MLXArray(samples),
            samples: samples,
            durationSec: Double(samples.count) / Double(sampleRate),
            target: target
        )
    }
}

func loadMonoSamples(from url: URL, sampleRate: Int) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw ReplayError.message("Could not allocate audio buffer for \(url.lastPathComponent)")
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else {
        throw ReplayError.message("Could not read audio samples for \(url.lastPathComponent)")
    }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var mixed = [Float](repeating: 0, count: frames)
    if channelCount <= 1 {
        mixed = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    } else {
        let scale = 1 / Float(channelCount)
        for ch in 0..<channelCount {
            let data = channels[ch]
            for i in 0..<frames {
                mixed[i] += data[i] * scale
            }
        }
    }
    let sourceRate = Int(format.sampleRate)
    if sourceRate == sampleRate {
        return mixed
    }
    return try resampleAudio(mixed, from: sourceRate, to: sampleRate)
}

// MARK: - Inference

func warmup(moss: MossFormer2SEModel, dfn: DeepFilterNetModel?) throws {
    let noise = MLXArray((0..<48_000).map { _ in Float.random(in: -0.05...0.05) })
    eval(try moss.enhance(noise))
    if let dfn {
        eval(try dfn.enhance(noise))
    }
    Memory.clearCache()
}

func enhance(
    audio: MLXArray,
    recipe: Recipe,
    moss: MossFormer2SEModel,
    dfn: DeepFilterNetModel?
) throws -> [Float] {
    switch recipe.backend {
    case .deepfilternet:
        guard let dfn else {
            throw ReplayError.message("DeepFilterNet was not loaded")
        }
        switch recipe.mode {
        case .dfnOffline:
            let out = try dfn.enhance(audio)
            eval(out)
            return out.asArray(Float.self)
        case .dfnStream:
            let chunk = max(dfn.config.hopSize, Int(Float(dfn.sampleRate) * (recipe.chunkSeconds ?? 0.48)))
            let out: MLXArray = try dfn.enhanceStreaming(audio, chunkSamples: chunk)
            eval(out)
            return out.asArray(Float.self)
        default:
            throw ReplayError.message("Unsupported DFN mode \(recipe.mode.rawValue)")
        }
    case .mossformer:
        switch recipe.mode {
        case .full:
            let out = try moss.enhance(audio)
            eval(out)
            return out.asArray(Float.self)
        case .segmented:
            return try enhanceSegmented(
                audio: audio,
                moss: moss,
                decodeWindow: recipe.decodeWindow ?? 4
            )
        case .chunkedDiscard:
            return try enhanceChunkedDiscard(
                audio: audio,
                moss: moss,
                chunkSeconds: recipe.chunkSeconds ?? 4,
                overlapRatio: recipe.overlapRatio ?? 0.25
            )
        case .chunkedOLA:
            return try enhanceChunkedOLA(
                audio: audio,
                moss: moss,
                chunkSeconds: recipe.chunkSeconds ?? 4,
                overlapSeconds: recipe.overlapSeconds ?? 0.5
            )
        default:
            throw ReplayError.message("Unsupported MossFormer mode \(recipe.mode.rawValue)")
        }
    }
}

func enhanceSegmented(audio: MLXArray, moss: MossFormer2SEModel, decodeWindow: Float) throws -> [Float] {
    let sampleRate = moss.sampleRate
    var input = audio.asArray(Float.self)
    let originalLen = input.count
    let windowSize = Int(Float(sampleRate) * decodeWindow)
    let stride = Int(Float(windowSize) * 0.75)
    let t0 = input.count
    if t0 < windowSize {
        input += [Float](repeating: 0, count: windowSize - t0)
    } else if t0 < windowSize + stride {
        input += [Float](repeating: 0, count: windowSize + stride - t0)
    } else if (t0 - windowSize) % stride != 0 {
        let padding = t0 - ((t0 - windowSize) / stride) * stride
        input += [Float](repeating: 0, count: padding)
    }

    let giveUp = (windowSize - stride) / 2
    var output = [Float](repeating: 0, count: input.count)
    var current = 0
    while current + windowSize <= input.count {
        let chunk = Array(input[current..<(current + windowSize)])
        let enhanced = try moss.enhance(MLXArray(chunk)).asArray(Float.self)
        eval(MLXArray(enhanced))
        Memory.clearCache()
        if current == 0 {
            let end = min(windowSize - giveUp, enhanced.count)
            output.replaceSubrange(current..<(current + end), with: enhanced[0..<end])
        } else {
            let start = giveUp
            let end = min(windowSize - giveUp, enhanced.count)
            if start < end {
                output.replaceSubrange((current + start)..<(current + end), with: enhanced[start..<end])
            }
        }
        current += stride
    }
    return Array(output.prefix(originalLen))
}

func enhanceChunkedDiscard(
    audio: MLXArray,
    moss: MossFormer2SEModel,
    chunkSeconds: Float,
    overlapRatio: Float
) throws -> [Float] {
    let input = audio.asArray(Float.self)
    let originalLen = input.count
    let chunkSamples = Int(Float(moss.sampleRate) * chunkSeconds)
    let overlapSamples = Int(Float(chunkSamples) * overlapRatio)
    let stride = max(1, chunkSamples - overlapSamples)
    let giveUp = overlapSamples / 2

    if originalLen <= chunkSamples {
        let out = try moss.enhance(audio)
        eval(out)
        return out.asArray(Float.self)
    }

    var output = [Float](repeating: 0, count: originalLen)
    var starts: [Int] = []
    var current = 0
    while current + chunkSamples <= originalLen {
        starts.append(current)
        current += stride
    }
    if current < originalLen {
        starts.append(current)
    }

    for (idx, startIdx) in starts.enumerated() {
        let isLast = idx == starts.count - 1
        let endIdx = isLast ? originalLen : min(startIdx + chunkSamples, originalLen)
        let chunk = Array(input[startIdx..<endIdx])
        let enhanced = try moss.enhance(MLXArray(chunk)).asArray(Float.self)
        eval(MLXArray(enhanced))
        Memory.clearCache()
        let chunkLen = enhanced.count
        let keepStart = (idx == 0) ? 0 : giveUp
        let keepEnd: Int
        if isLast && chunkLen < chunkSamples {
            keepEnd = chunkLen
        } else {
            keepEnd = max(keepStart, chunkLen - giveUp)
        }
        let outputStart = startIdx + keepStart
        let outputEnd = min(startIdx + keepEnd, originalLen)
        let copyCount = outputEnd - outputStart
        if copyCount > 0 {
            output.replaceSubrange(outputStart..<outputEnd, with: enhanced[keepStart..<(keepStart + copyCount)])
        }
    }
    return output
}

func enhanceChunkedOLA(
    audio: MLXArray,
    moss: MossFormer2SEModel,
    chunkSeconds: Float,
    overlapSeconds: Float
) throws -> [Float] {
    let input = audio.asArray(Float.self)
    let originalLen = input.count
    let chunk = Int(Float(moss.sampleRate) * chunkSeconds)
    let overlap = Int(Float(moss.sampleRate) * overlapSeconds)
    let step = max(1, chunk - overlap)
    if originalLen <= chunk {
        let out = try moss.enhance(audio)
        eval(out)
        return out.asArray(Float.self)
    }

    var output = [Float](repeating: 0, count: originalLen + chunk)
    var weight = [Float](repeating: 0, count: originalLen + chunk)
    var start = 0
    while true {
        let end = min(start + chunk, originalLen)
        var segment = Array(input[start..<end])
        if segment.count < chunk {
            segment += [Float](repeating: 0, count: chunk - segment.count)
        }
        var enhanced = try moss.enhance(MLXArray(segment)).asArray(Float.self)
        eval(MLXArray(enhanced))
        Memory.clearCache()
        if enhanced.count > chunk {
            enhanced = Array(enhanced.prefix(chunk))
        } else if enhanced.count < chunk {
            enhanced += [Float](repeating: 0, count: chunk - enhanced.count)
        }
        var window = [Float](repeating: 1, count: enhanced.count)
        if overlap > 0 && enhanced.count >= 2 * overlap {
            for i in 0..<overlap {
                let fade = Float(i) / Float(max(overlap - 1, 1))
                window[i] *= fade
                window[enhanced.count - overlap + i] *= (1 - fade)
            }
        }
        for i in 0..<enhanced.count {
            output[start + i] += enhanced[i] * window[i]
            weight[start + i] += window[i]
        }
        if end >= originalLen { break }
        start += step
    }
    for i in 0..<originalLen {
        output[i] /= max(weight[i], 1e-8)
    }
    return Array(output.prefix(originalLen))
}

// MARK: - Metrics

func seconds(from start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

func finiteOrNil(_ value: Float?) -> Float? {
    guard let value, value.isFinite else { return nil }
    return value
}

func finiteSampleRatio(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let finite = samples.reduce(into: 0) { count, sample in
        if sample.isFinite { count += 1 }
    }
    return Float(finite) / Float(samples.count)
}

func correlation(_ lhs: [Float], _ rhs: [Float]) -> Float {
    let n = min(lhs.count, rhs.count)
    guard n > 0 else { return 0 }
    var meanX: Float = 0
    var meanY: Float = 0
    for i in 0..<n {
        meanX += lhs[i]
        meanY += rhs[i]
    }
    meanX /= Float(n)
    meanY /= Float(n)
    var num: Float = 0
    var denX: Float = 0
    var denY: Float = 0
    for i in 0..<n {
        let dx = lhs[i] - meanX
        let dy = rhs[i] - meanY
        num += dx * dy
        denX += dx * dx
        denY += dy * dy
    }
    return num / sqrt(max(denX * denY, 1e-20))
}

func siSDR(estimate: [Float], reference: [Float]) -> Float {
    let n = min(estimate.count, reference.count)
    guard n > 0 else { return 0 }
    var dotER: Float = 0
    var dotRR: Float = 0
    for i in 0..<n {
        dotER += estimate[i] * reference[i]
        dotRR += reference[i] * reference[i]
    }
    let alpha = dotER / max(dotRR, 1e-12)
    var targetEnergy: Float = 0
    var errorEnergy: Float = 0
    for i in 0..<n {
        let target = alpha * reference[i]
        let error = estimate[i] - target
        targetEnergy += target * target
        errorEnergy += error * error
    }
    return 10 * log10(max(targetEnergy, 1e-12) / max(errorEnergy, 1e-12))
}

func residualRmsRatio(input: [Float], enhanced: [Float]) -> Float {
    let n = min(input.count, enhanced.count)
    guard n > 0 else { return 0 }
    var inputEnergy: Float = 0
    var residualEnergy: Float = 0
    for i in 0..<n {
        inputEnergy += input[i] * input[i]
        let r = input[i] - enhanced[i]
        residualEnergy += r * r
    }
    let inputRms = sqrt(inputEnergy / Float(n))
    let residualRms = sqrt(residualEnergy / Float(n))
    return residualRms / max(inputRms, 1e-12)
}

func spliceJumpRMS(
    samples: [Float],
    sampleRate: Int,
    chunkSeconds: Float?,
    overlapSeconds: Float?,
    overlapRatio: Float?
) -> Float? {
    guard let chunkSeconds else { return nil }
    let chunk = Int(Float(sampleRate) * chunkSeconds)
    let overlap: Int
    if let overlapSeconds {
        overlap = Int(Float(sampleRate) * overlapSeconds)
    } else if let overlapRatio {
        overlap = Int(Float(chunk) * overlapRatio)
    } else {
        return nil
    }
    let stride = max(1, chunk - overlap)
    guard samples.count > stride else { return nil }
    var sum: Float = 0
    var count = 0
    var index = stride
    while index < samples.count {
        let jump = abs(samples[index] - samples[index - 1])
        sum += jump * jump
        count += 1
        index += stride
    }
    guard count > 0 else { return nil }
    return sqrt(sum / Float(count))
}

// MARK: - Report

struct Report: Encodable {
    let createdAt: String
    let mossRepo: String
    let dfnRepo: String
    let sampleRate: Int
    let fixtures: [FixtureSummary]
    var runs: [RunResult]
}

struct RunResult: Encodable {
    let fixture: String
    let recipe: String
    let backend: String
    let mode: String
    let ok: Bool
    let error: String?
    let elapsedSec: Double
    let rtf: Double
    let mlxPeakBytes: Int
    let outputSamples: Int
    let chunkCount: Int
    let corrVsMossFull: Float?
    let corrVsDfnOffline: Float?
    let siSdrVsTargetDb: Float?
    let residualRmsRatio: Float?
    let spliceJumpRms: Float?
    let finiteSampleRatio: Float?
    let wavPath: String?
}

func markdown(for report: Report) -> String {
    var lines = [
        "# MossFormer2-SE FP16 experiment results",
        "",
        "Generated: \(report.createdAt)",
        "",
        "- MossFormer: `\(report.mossRepo)`",
        "- DeepFilterNet: `\(report.dfnRepo)`",
        "- Sample rate: \(report.sampleRate) Hz",
        "",
    ]
    for fixture in report.fixtures {
        lines.append("## \(fixture.id) (\(String(format: "%.1f", fixture.durationSec))s)")
        lines.append("")
        lines.append("| Recipe | OK | Elapsed | RTF | Peak MB | corr vs moss_full | corr vs dfn | SI-SDR dB | residual | splice RMS | finite |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for run in report.runs where run.fixture == fixture.id {
            lines.append(
                "| \(run.recipe) | \(run.ok ? "yes" : "no") | \(fmt(run.elapsedSec)) | \(fmt(run.rtf)) | \(fmt(Double(run.mlxPeakBytes) / 1_000_000)) | \(fmt(run.corrVsMossFull)) | \(fmt(run.corrVsDfnOffline)) | \(fmt(run.siSdrVsTargetDb)) | \(fmt(run.residualRmsRatio)) | \(fmt(run.spliceJumpRms)) | \(fmt(run.finiteSampleRatio)) |"
            )
        }
        lines.append("")
    }
    lines.append("WAV files are beside this report. Listen to `short__moss_full.wav` vs `short__dfn_offline.wav` first, then the matching long-audio chunked variants.")
    lines.append("")
    return lines.joined(separator: "\n")
}

func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
func fmt(_ value: Float?) -> String {
    guard let value, value.isFinite else { return "-" }
    return String(format: "%.4f", value)
}
