import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VoxstudioPro

/// Incident-only preprocessing. It does not change the product's dub defaults.
private enum UmbrellaSplitter {
    enum Failure: Error { case noSafeBoundary }

    static func normalize(_ text: String) -> String {
        TranscriptSegmenter.normalizeDisplayText(text, language: "en")
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "…", with: "……")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func elastic(_ text: String, maximum: Int = 200, tolerance: Double = 0.2) throws -> [String] {
        let characters = Array(normalize(text))
        let lower = max(1, Int((Double(maximum) * (1 - tolerance)).rounded(.down)))
        let upper = max(lower, Int((Double(maximum) * (1 + tolerance)).rounded(.up)))
        var candidates: [(end: Int, rank: Int)] = []
        var quotes: [Character] = []
        for i in characters.indices {
            let c = characters[i]
            if c == "“" { quotes.append("”") }
            else if c == "”", quotes.last == c { quotes.removeLast() }
            else if c == "\"" {
                if quotes.last == c { quotes.removeLast() } else { quotes.append(c) }
            }
            var end = i + 1
            var closing = quotes
            if ".!?。！？".contains(c) {
                // A quoted sentence ends only after the complete quotation.
                while end < characters.count, closing.last == characters[end] {
                    closing.removeLast()
                    end += 1
                }
                let decimal = c == "." && i > 0 && i + 1 < characters.count
                    && characters[i - 1].isNumber && characters[i + 1].isNumber
                if closing.isEmpty && !decimal { candidates.append((end, 0)) }
            } else if quotes.isEmpty {
                if ";:；：".contains(c) { candidates.append((end, 1)) }
                else if ",，".contains(c) { candidates.append((end, 2)) }
                else if c.isWhitespace { candidates.append((i, 3)) }
            }
        }
        var result: [String] = []
        var start = 0
        while start < characters.count {
            if characters.count - start <= upper {
                result.append(String(characters[start...]))
                break
            }
            let window = candidates.filter { (lower...upper).contains($0.end - start) }
            let selected = window.min {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                let a = abs($0.end - start - maximum), b = abs($1.end - start - maximum)
                return a == b ? $0.end < $1.end : a < b
            } ?? candidates.filter { $0.end > start && $0.end - start <= upper }
                .max { $0.end < $1.end }
            guard let selected else { throw Failure.noSafeBoundary }
            result.append(String(characters[start..<selected.end]).trimmingCharacters(in: .whitespaces))
            start = selected.end
            while start < characters.count, characters[start].isWhitespace { start += 1 }
        }
        return result
    }
}

@Suite("Red Umbrella split checks")
struct RedUmbrellaSplitTests {
    private let sentences = [
        "On a rainy afternoon, Emma found a small red umbrella on a bench near the park.",
        "She looked around, but no one was there.",
        "Instead of taking it home, she waited under a tree, hoping the owner would return.",
        "Twenty minutes later, an old woman hurried toward the bench.",
        "She looked worried and searched everywhere.",
        "Emma walked over and asked, “Are you looking for this?”",
        "The woman smiled with relief.",
        "“Yes! My husband gave it to me many years ago.”",
        "She thanked Emma warmly.",
        "As Emma walked home in the rain, she felt happy.",
        "A small act of kindness had made someone’s day."
    ]

    @Test func plannedCutsPreserveTextAndQuotations() throws {
        let text = UmbrellaSplitter.normalize(sentences.joined(separator: " "))
        let chunks = try UmbrellaSplitter.elastic(text)
        #expect(chunks.map(\.count) == [203, 190, 169])
        #expect(chunks == [sentences[0..<3], sentences[3..<7], sentences[7..<11]]
            .map { UmbrellaSplitter.normalize($0.joined(separator: " ")) })
        #expect(chunks.joined(separator: " ") == text)
        #expect(chunks[1].contains("The woman"))
        #expect(chunks[2].contains("years ago"))
        #expect(!chunks.contains { $0.hasSuffix("\"Yes!") || $0.hasSuffix("“Yes!") })
    }

    @Test func punctuationOutranksCloserWhitespace() throws {
        let text = "aaaaa. bbbbbbb ccccccc ddddddd eeeeeee"
        let chunks = try UmbrellaSplitter.elastic(text, maximum: 10, tolerance: 0.5)
        #expect(chunks[0] == "aaaaa.")
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func equalDistanceChoosesEarlierEnd() throws {
        let text = "aaaaaa. bb. cccccccccc. dddddddddd."
        let chunks = try UmbrellaSplitter.elastic(text, maximum: 9, tolerance: 0.4)
        #expect(chunks[0] == "aaaaaa.")
    }

    @Test func decimalAndUnpunctuatedTextKeepWords() throws {
        let text = "Costs 12.50 dollars today and tomorrow too"
        let chunks = try UmbrellaSplitter.elastic(text, maximum: 16, tolerance: 0.25)
        #expect(chunks.joined(separator: " ") == text)
        #expect(!chunks.contains { $0.hasSuffix("12.") })
        #expect(throws: UmbrellaSplitter.Failure.self) {
            try UmbrellaSplitter.elastic(String(repeating: "x", count: 30), maximum: 10)
        }
    }
}

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import MLXAudioTTS

/// Opt-in model replay: exactly two strategies and five unique synthesis inputs.
@Suite("Red Umbrella dub diagnosis", .serialized)
struct RedUmbrellaDubExperimentTests {
    private static let inputPath = ProcessInfo.processInfo.environment["VOXSTUDIO_RED_UMBRELLA_INPUT"]
    private static let inspect = ProcessInfo.processInfo.environment["VOXSTUDIO_RED_UMBRELLA_INSPECT"] == "1"
    private static let tailCheck = ProcessInfo.processInfo.environment["VOXSTUDIO_RED_UMBRELLA_TAIL_CHECK"] == "1"

    private struct Input: Decodable {
        var jobID: String
        var script: String
        var reference: DubVoiceReference
        var modelPath: String
        var outputDirectory: String
        var sentences: [String]
    }

    private struct Chunk: Codable {
        var id: String
        var text: String
        var filename: String
        var duration: Double
        var synthesisSeconds: Double
        var mlxActiveBeforeBytes: Int
        var mlxPeakBytes: Int
        var processBefore: ProcessMemory
        var processAfter: ProcessMemory
        var sampledProcessPeak: ProcessMemory
        var sha256: String
        var decodedRawFrames: Int?
        var decodedRepairedFrames: Int?
        var repairedDuration: Double?
        var speechSpans: [VoiceActivity.Span]?
    }

    private struct Result: Codable {
        var name: String
        var chunkIDs: [String]
        var synthesisSeconds: Double
        var rawDuration: Double
        var repairedDuration: Double
        var renderedSegments: [DubRenderedSegment]
        var rawRenderedSegments: [DubRenderedSegment]?
    }

    private struct Manifest: Codable {
        var schemaVersion = 2
        var normalizedScript: String
        var seed: UInt64
        var modelPath: String
        var referencePath: String
        var referenceTranscript: String
        var referenceSHA256: String
        var physicalMemoryBytes: UInt64
        var maximumCharacters = 200
        var tolerance = 0.2
        var gapSeconds = 0.2
        var modelLoadSeconds: Double = 0
        var modelLoadMLXPeakBytes: Int = 0
        var chunks: [Chunk] = []
        var cases: [Result] = []
    }

    @Test(.enabled(if: inputPath != nil && !inspect && !tailCheck))
    func runTwoChunkStrategies() async throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf:
            URL(fileURLWithPath: try #require(Self.inputPath))))
        let directory = URL(fileURLWithPath: input.outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = UmbrellaSplitter.normalize(input.script)
        let sentences = input.sentences.map(UmbrellaSplitter.normalize)
        #expect(sentences.joined(separator: " ") == script)
        let semantic = [sentences[0..<3], sentences[3..<9], sentences[9..<11]]
            .map { $0.joined(separator: " ") }
        let elastic = try UmbrellaSplitter.elastic(script)
        #expect(semantic.map(\.count) == [203, 263, 96])
        #expect(elastic.map(\.count) == [203, 190, 169])
        #expect(semantic.joined(separator: " ") == script)
        #expect(elastic.joined(separator: " ") == script)
        #expect(semantic[0] == elastic[0])
        let seed = DubSeed.deterministic(language: "en", text: "\(input.jobID)\n\(input.script)")
        #expect(seed == 3_844_248_867_990_166_603)
        let referenceData = try Data(contentsOf: input.reference.audioURL)
        var manifest = Manifest(normalizedScript: script, seed: seed, modelPath: input.modelPath,
            referencePath: input.reference.audioURL.path, referenceTranscript: input.reference.transcript,
            referenceSHA256: sha(referenceData), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        // A failed later analysis may be resumed without generating any saved input twice.
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let saved = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            #expect(saved.normalizedScript == script && saved.seed == seed)
            #expect(saved.modelPath == input.modelPath && saved.referenceSHA256 == manifest.referenceSHA256)
            manifest = saved
        }
        let inputs = [("shared-0", semantic[0]), ("A-1", semantic[1]), ("A-2", semantic[2]),
                      ("B-1", elastic[1]), ("B-2", elastic[2])]
        if manifest.chunks.count < inputs.count {
            let model = try await loadModel(input.modelPath, manifest: &manifest)
            try save(manifest, to: manifestURL)
            let referenceSamples = try AudioFileLoader.load(url: input.reference.audioURL, targetSampleRate: 24_000)
            for (id, text) in inputs {
                if let previous = manifest.chunks.first(where: { $0.id == id }) {
                    #expect(previous.text == text)
                    #expect(sha(try Data(contentsOf: directory.appendingPathComponent(previous.filename))) == previous.sha256)
                    continue
                }
                let chunk = try await synthesize(id: id, text: text, seed: seed, model: model,
                    referenceSamples: referenceSamples, referenceText: input.reference.transcript, directory: directory)
                manifest.chunks.append(chunk)
                try save(manifest, to: manifestURL)
            }
        }
        #expect(manifest.chunks.count == 5)
        for index in manifest.chunks.indices {
            let chunk = manifest.chunks[index]
            let samples = try AudioFileLoader.load(url: directory.appendingPathComponent(chunk.filename), targetSampleRate: 24_000)
            // Preserve the current product reader, but report any lost WAV tail
            // separately from VAD removal. AVAudioFile can require another read.
            manifest.chunks[index].decodedRawFrames = samples.count
            let analysis = try await SpeechAnalysisService.shared.analyze(
                samples: AudioFileLoader.resample(samples, from: 24_000, to: 16_000), progress: { _, _, _ in })
            let spans = analysis.segments.map {
                VoiceActivity.Span(start: Double($0.startTime), end: Double($0.endTime))
            }
            let repaired = VoiceActivity.repairingLongSilence(in: samples, sampleRate: 24_000, speechSpans: spans)
            try write(repaired, to: directory.appendingPathComponent("\(chunk.id)-repaired.wav"))
            manifest.chunks[index].speechSpans = spans
            manifest.chunks[index].repairedDuration = Double(repaired.count) / 24_000
            try save(manifest, to: manifestURL)
        }
        manifest.cases = []
        for (name, ids) in [("A-semantic", ["shared-0", "A-1", "A-2"]),
                            ("B-elastic", ["shared-0", "B-1", "B-2"])] {
            var raw: [LocalDubFlowRenderer.GeneratedSegment] = []
            var repaired: [LocalDubFlowRenderer.GeneratedSegment] = []
            var seconds = 0.0
            for (index, id) in ids.enumerated() {
                let chunk = try #require(manifest.chunks.first { $0.id == id })
                let source = DubSegmentPayload(index: index, text: chunk.text, speaker: input.reference.name)
                let rawSamples = try AudioFileLoader.load(
                    url: directory.appendingPathComponent(chunk.filename), targetSampleRate: 24_000)
                let repairedSamples = try AudioFileLoader.load(
                    url: directory.appendingPathComponent("\(id)-repaired.wav"), targetSampleRate: 24_000)
                raw.append(.init(source: source, samples: rawSamples))
                repaired.append(.init(source: source, samples: repairedSamples))
                let recordIndex = try #require(manifest.chunks.firstIndex { $0.id == id })
                manifest.chunks[recordIndex].decodedRepairedFrames = repairedSamples.count
                seconds += chunk.synthesisSeconds
            }
            let assembled = LocalDubFlowRenderer.assemble(repaired, sampleRate: 24_000, gapSeconds: 0.2)
            let untouched = LocalDubFlowRenderer.assemble(raw, sampleRate: 24_000, gapSeconds: 0.2)
            try write(assembled.samples, to: directory.appendingPathComponent("\(name).wav"))
            try write(untouched.samples, to: directory.appendingPathComponent("\(name)-without-repair.wav"))
            manifest.cases.append(.init(name: name, chunkIDs: ids, synthesisSeconds: seconds,
                rawDuration: Double(untouched.samples.count) / 24_000,
                repairedDuration: Double(assembled.samples.count) / 24_000,
                renderedSegments: assembled.segments, rawRenderedSegments: untouched.segments))
            try save(manifest, to: manifestURL)
            print("[umbrella] finished \(name) synth=\(seconds)s audio=\(Double(assembled.samples.count) / 24_000)s")
        }
    }

    private func loadModel(_ path: String, manifest: inout Manifest) async throws -> Qwen3TTSModel {
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }
        Memory.peakMemory = 0
        let started = Date()
        let model = try #require(try await TTS.loadModel(modelRepo: path) as? Qwen3TTSModel)
        manifest.modelLoadSeconds = Date().timeIntervalSince(started)
        manifest.modelLoadMLXPeakBytes = Memory.peakMemory
        print("[umbrella] model loaded in \(manifest.modelLoadSeconds)s seed=\(manifest.seed)")
        return model
    }

    private func synthesize(id: String, text: String, seed: UInt64, model: Qwen3TTSModel,
        referenceSamples: [Float], referenceText: String, directory: URL) async throws -> Chunk {
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }
        Memory.peakMemory = 0
        let active = Memory.activeMemory
        let probe = ProcessProbe()
        probe.start()
        defer { probe.stop() }
        let before = ProcessMemory.read()
        print("[umbrella] BEGIN \(id) chars=\(text.count) text=\(text)")
        let started = Date()
        // Exactly the app's non-streaming generate path: fresh reference and seed per call.
        // generate creates a new talker KV cache; no product text preprocessor is called.
        let reference = MLXArray(referenceSamples)
        MLXRandom.seed(seed)
        let audio = try await model.generate(text: text, voice: nil, refAudio: reference,
            refText: referenceText, language: "english")
        let samples = audio.asArray(Float.self)
        let seconds = Date().timeIntervalSince(started)
        let peak = Memory.peakMemory
        let after = ProcessMemory.read()
        probe.stop()
        #expect(!samples.isEmpty && samples.allSatisfy(\.isFinite))
        let filename = "\(id)-raw.wav"
        let url = directory.appendingPathComponent(filename)
        try write(samples, to: url)
        print("[umbrella] END \(id) seconds=\(seconds) duration=\(Double(samples.count) / 24_000) mlxPeak=\(peak)")
        return Chunk(id: id, text: text, filename: filename, duration: Double(samples.count) / 24_000,
            synthesisSeconds: seconds, mlxActiveBeforeBytes: active, mlxPeakBytes: peak,
            processBefore: before, processAfter: after, sampledProcessPeak: probe.peak,
            sha256: sha(try Data(contentsOf: url)))
    }

    @Test(.enabled(if: inputPath != nil && inspect))
    func inspectSavedAudio() async throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf:
            URL(fileURLWithPath: try #require(Self.inputPath))))
        let directory = URL(fileURLWithPath: input.outputDirectory, isDirectory: true)
        for name in ["original-version2", "A-semantic", "B-elastic"] {
            let url = directory.appendingPathComponent("\(name).wav")
            // Free ASR, with no supplied script, can detect missing/repeated speech.
            let result = try await LocalSpeechPipeline.shared.transcribe(sourceURL: url,
                languageCode: "en", speakerCount: 1, progress: { _, _ in })
            try save(result, to: directory.appendingPathComponent("\(name)-asr.json"))
            let aligned = try await LocalSpeechPipeline.shared.alignScript(sourceURL: url,
                text: UmbrellaSplitter.normalize(input.script), languageCode: "en", speakerCount: 1)
            try save(aligned, to: directory.appendingPathComponent("\(name)-alignment.json"))
            print("[umbrella] inspected \(name)")
        }
        await LocalSpeechPipeline.shared.releaseLane()
    }

    @Test(.enabled(if: inputPath != nil && tailCheck))
    func checkSuspectedBTailWithWhisper() async throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf:
            URL(fileURLWithPath: try #require(Self.inputPath))))
        let directory = URL(fileURLWithPath: input.outputDirectory, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            directory.appendingPathComponent("manifest.json")))
        let b = try #require(manifest.cases.first { $0.name == "B-elastic" })
        let start = try #require(b.renderedSegments.last?.start)
        for (name, filename, range) in [
            ("B-raw-tail", "B-2-raw.wav", nil as ClosedRange<Double>?),
            ("B-final-tail", "B-elastic.wav", start...b.repairedDuration)
        ] {
            let result = try await LocalSpeechPipeline.shared.transcribeWhisperForTuning(
                sourceURL: directory.appendingPathComponent(filename), languageCode: "en",
                clipRangeSeconds: range, profile: WhisperASRTuningProfile.matrix[0])
            try save(result, to: directory.appendingPathComponent("\(name)-whisper.json"))
            print("[umbrella] independent tail check \(name): \(result.text)")
        }
        await LocalSpeechPipeline.shared.releaseLane()
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    private func write(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}

private struct ProcessMemory: Codable, Sendable {
    var residentBytes: UInt64 = 0
    var physicalFootprintBytes: UInt64 = 0

    static func read() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return Self() }
        return Self(residentBytes: info.resident_size, physicalFootprintBytes: info.phys_footprint)
    }
}

/// Sample process memory every 20 ms; MLX peak is independently recorded by MLX.
private final class ProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum = ProcessMemory()
    private var timer: DispatchSourceTimer?
    var peak: ProcessMemory { lock.withLock { maximum } }
    func start() {
        sample()
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }
    func stop() { timer?.cancel(); timer = nil; sample() }
    private func sample() {
        let value = ProcessMemory.read()
        lock.withLock {
            maximum.residentBytes = max(maximum.residentBytes, value.residentBytes)
            maximum.physicalFootprintBytes = max(maximum.physicalFootprintBytes, value.physicalFootprintBytes)
        }
    }
}
#endif
