import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

#if BUNDLED_SPEECH
import AudioCommon
import MLX
import Qwen3TTS

@Suite("Qwen3 TTS clone experiment", .serialized)
struct TTSCloneExperimentTests {
    private static let enabled = ProcessInfo.processInfo.environment[
        "VOXELLA_RUN_TTS_CLONE_EXPERIMENT"
    ] == "1"

    private static let referenceURL = AppSupportPaths.applicationSupport()
        .appendingPathComponent("VoiceLibrary/D0AA2E85-0D7C-4157-8424-47FE656D7750/reference.wav")
    private static let referenceText = "这时一个测试， 这个音色会被用作参考"
    private static let targetText = "我从2000年开始出现咳嗽的现象，到2017年12月咳嗽加重，感觉好像整天都在咳嗽。"
    private static let seed: UInt64 = 0x564F5845

    @Test(.enabled(if: enabled))
    func adReferenceComparesCloneConditioningAndSampling() async throws {
        let outputDirectory = try outputDirectory()
        let descriptor = try #require(
            LocalModelManager.catalog.first { $0.id == .qwenTTS17B }
        )
        #expect(LocalModelManager.isInstalled(descriptor))

        let reference = try AudioFileLoader.load(
            url: Self.referenceURL,
            targetSampleRate: 24_000
        )
        #expect(!reference.isEmpty)

        let (model, encoder) = try await Qwen3TTSModel.fromPretrainedWithEncoder(
            modelId: descriptor.repository,
            cacheDir: LocalModelManager.directory(for: descriptor.id),
            offlineMode: true
        )

        let language = LocalDubPipeline.ttsLanguage("zh", script: Self.targetText)
        var standardSampling = SamplingConfig()
        standardSampling.temperature = 0.9
        standardSampling.topK = 50
        standardSampling.topP = 1
        standardSampling.repetitionPenalty = 1.05

        let cases: [(String, String, () -> [Float])] = [
            (
                "A-current-xvector-greedy",
                "Current app: x-vector only + greedy decoding",
                {
                    MLXRandom.seed(Self.seed)
                    return model.synthesizeWithVoiceClone(
                        text: Self.targetText,
                        referenceAudio: reference,
                        referenceSampleRate: 24_000,
                        language: language,
                        sampling: .greedy
                    )
                }
            ),
            (
                "B-xvector-default-sampling",
                "x-vector only + Qwen default sampling",
                {
                    MLXRandom.seed(Self.seed)
                    return model.synthesizeWithVoiceClone(
                        text: Self.targetText,
                        referenceAudio: reference,
                        referenceSampleRate: 24_000,
                        language: language,
                        sampling: standardSampling
                    )
                }
            ),
            (
                "C-icl-greedy",
                "ICL conditioning + greedy decoding",
                {
                    MLXRandom.seed(Self.seed)
                    return model.synthesizeWithVoiceCloneICL(
                        text: Self.targetText,
                        referenceAudio: reference,
                        referenceSampleRate: 24_000,
                        referenceText: Self.referenceText,
                        language: language,
                        sampling: .greedy,
                        codecEncoder: encoder,
                        trimReference: true
                    )
                }
            ),
            (
                "D-icl-default-sampling",
                "Pre-regression app path: ICL conditioning + Qwen default sampling",
                {
                    MLXRandom.seed(Self.seed)
                    return model.synthesizeWithVoiceCloneICL(
                        text: Self.targetText,
                        referenceAudio: reference,
                        referenceSampleRate: 24_000,
                        referenceText: Self.referenceText,
                        language: language,
                        sampling: standardSampling,
                        codecEncoder: encoder,
                        trimReference: true
                    )
                }
            ),
        ]

        var results: [ExperimentResult] = []
        for (name, description, synthesis) in cases {
            let samples = synthesis()
            #expect(!samples.isEmpty, "\(name) produced no samples")
            let outputURL = outputDirectory.appendingPathComponent("\(name).wav")
            try writeWAV(samples, to: outputURL)
            let metrics = try audioMetrics(for: outputURL)
            print("[tts-clone] \(name) duration=\(metrics.durationSeconds)s rms=\(metrics.rms) peak=\(metrics.peak)")
            results.append(ExperimentResult(
                name: name,
                description: description,
                outputFilename: outputURL.lastPathComponent,
                metrics: metrics
            ))
        }

        let manifest = ExperimentManifest(
            modelRepository: descriptor.repository,
            modelRevision: descriptor.revision,
            referenceAudioPath: Self.referenceURL.path,
            referenceTranscript: Self.referenceText,
            targetText: Self.targetText,
            language: language,
            seed: Self.seed,
            results: results
        )
        let data = try JSONEncoder.pretty.encode(manifest)
        try data.write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func outputDirectory() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["VOXELLA_TTS_EXPERIMENT_OUTPUT"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let capacity = try #require(AVAudioFrameCount(exactly: samples.count))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = capacity
        let channel = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func audioMetrics(for url: URL) throws -> AudioMetrics {
        let file = try AVAudioFile(forReading: url)
        let capacity = try #require(AVAudioFrameCount(exactly: file.length))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        let squared = (0..<count).reduce(0.0) { partial, index in
            partial + Double(samples[index] * samples[index])
        }
        let peak = (0..<count).reduce(Float.zero) { partial, index in
            max(partial, abs(samples[index]))
        }
        return AudioMetrics(
            durationSeconds: Double(count) / file.processingFormat.sampleRate,
            rms: sqrt(squared / Double(max(1, count))),
            peak: Double(peak)
        )
    }
}

private struct ExperimentManifest: Codable {
    var modelRepository: String
    var modelRevision: String
    var referenceAudioPath: String
    var referenceTranscript: String
    var targetText: String
    var language: String
    var seed: UInt64
    var results: [ExperimentResult]
}

private struct ExperimentResult: Codable {
    var name: String
    var description: String
    var outputFilename: String
    var metrics: AudioMetrics
}

private struct AudioMetrics: Codable {
    var durationSeconds: Double
    var rms: Double
    var peak: Double
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
#endif
