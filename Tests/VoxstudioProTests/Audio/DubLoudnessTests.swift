import AVFoundation
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Dub segment loudness")
struct DubLoudnessTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["VOXSTUDIO_DUB_LEVEL_FIXTURE"]
    private static let runModel = ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"

    private func tone(amplitude: Float, frequency: Double = 997, seconds: Double = 2, rate: Int = 24_000) -> [Float] {
        (0..<Int(seconds * Double(rate))).map {
            amplitude * Float(sin(2 * .pi * frequency * Double($0) / Double(rate)))
        }
    }

    private func segment(_ index: Int, _ samples: [Float], start: Double? = nil) -> LocalDubFlowRenderer.GeneratedSegment {
        .init(source: .init(index: index, text: "Voice \(index)", start: start, speaker: "Reference \(index)"), samples: samples)
    }

    @Test func meterMatchesFullScale997HzCalibrationAtBothRates() throws {
        // BS.1770's calibration signal is a full-scale 997 Hz sine: -3.01 LUFS.
        for rate in [24_000, 48_000] {
            let measured = try #require(DubLoudnessNormalizer.integratedLUFS(in: tone(amplitude: 1, rate: rate), sampleRate: rate))
            #expect(abs(measured - (-3.01)) < 0.1)
        }
    }

    @Test func assemblyMatchesQuietAndLoudReferencesWithoutChangingRanges() throws {
        let quiet = tone(amplitude: 0.02)
        let loud = tone(amplitude: 0.2, frequency: 3_000)
        let result = LocalDubFlowRenderer.assemble([segment(0, quiet), segment(1, loud)], sampleRate: 24_000, gapSeconds: 0.2)
        let first = Array(result.samples[..<quiet.count])
        let second = Array(result.samples[(quiet.count + 4_800)...])
        let firstLUFS = try #require(DubLoudnessNormalizer.integratedLUFS(in: first, sampleRate: 24_000))
        let secondLUFS = try #require(DubLoudnessNormalizer.integratedLUFS(in: second, sampleRate: 24_000))
        #expect(abs(firstLUFS - (-18)) < 0.05)
        #expect(abs(firstLUFS - secondLUFS) < 0.05)
        #expect(result.segments.map(\.speaker) == ["Reference 0", "Reference 1"])
        #expect(result.segments.map(\.start) == [0, 2.2])
        #expect(result.segments.map(\.end) == [2, 4.2])
        #expect(result.samples[quiet.count..<(quiet.count + 4_800)].allSatisfy { $0 == 0 })
        // A single gain preserves the original waveform, rather than compressing it.
        let scale = first[1] / quiet[1]
        #expect(zip(first, quiet).allSatisfy { abs($0 - $1 * scale) < 0.00001 })
    }

    @Test func silenceDoesNotBiasMeasurementAndSubBlockSpeechIsSupported() throws {
        let speech = tone(amplitude: 0.1, seconds: 3)
        let padded = [Float](repeating: 0, count: 72_000) + speech + [Float](repeating: 0, count: 72_000)
        let original = try #require(DubLoudnessNormalizer.integratedLUFS(in: speech, sampleRate: 24_000))
        let withPauses = try #require(DubLoudnessNormalizer.integratedLUFS(in: padded, sampleRate: 24_000))
        #expect(abs(original - withPauses) < 0.5)
        let short = tone(amplitude: 0.04, seconds: 0.1)
        let gain = try #require(DubLoudnessNormalizer.gains(for: [short], sampleRate: 24_000).first)
        let normalized = try #require(DubLoudnessNormalizer.integratedLUFS(in: short.map { $0 * gain }, sampleRate: 24_000))
        #expect(abs(normalized - (-18)) < 0.05)
    }

    @Test func sharedHeadroomPreservesMatchWithHighCrestFactorAndOverlappingVoices() throws {
        var spiky = tone(amplitude: 0.02)
        spiky[24_000] = 0.9
        let smooth = tone(amplitude: 0.2)
        let result = LocalDubFlowRenderer.assemble([segment(0, spiky), segment(1, smooth)], sampleRate: 24_000, gapSeconds: 0)
        let first = try #require(DubLoudnessNormalizer.integratedLUFS(in: Array(result.samples[..<spiky.count]), sampleRate: 24_000))
        let second = try #require(DubLoudnessNormalizer.integratedLUFS(in: Array(result.samples[spiky.count...]), sampleRate: 24_000))
        #expect(abs(first - second) < 0.05)
        #expect(LinearLoudnessNormalizer.samplePeak(result.samples) <= 0.8912511)
        #expect(result.samples[24_000] > result.samples[23_999] * 10)

        let overlaps = (0..<10).map { segment($0, smooth, start: 0) }
        let mixed = LocalDubFlowRenderer.assemble(overlaps, sampleRate: 24_000, gapSeconds: 0)
        #expect(LinearLoudnessNormalizer.samplePeak(mixed.samples) <= 0.8912511)
        #expect(mixed.samples.count == smooth.count)
        let ratio = mixed.samples[1] / smooth[1]
        #expect(zip(mixed.samples, smooth).allSatisfy { abs($0 - $1 * ratio) < 0.00001 })
    }

    @Test func silenceNoiseAndNonFiniteSamplesStaySafe() {
        let silence = [Float](repeating: 0, count: 24_000)
        let noiseFloor = tone(amplitude: 0.00001)
        #expect(DubLoudnessNormalizer.integratedLUFS(in: silence, sampleRate: 24_000) == nil)
        #expect(DubLoudnessNormalizer.gains(for: [silence, noiseFloor, []], sampleRate: 24_000) == [1, 1, 1])
        let result = LocalDubFlowRenderer.assemble([segment(0, [.nan, .infinity, -.infinity, 0])], sampleRate: 24_000, gapSeconds: 0)
        #expect(result.samples == [0, 0, 0, 0])
    }

    private struct Fixture: Decodable {
        var originalPath: String
        var renderedSegments: [DubRenderedSegment]
        var segments: [DubSegmentPayload]
        var reference: DubVoiceReference
        var segmentReferences: [Int: DubVoiceReference]
        var language: String
        var seed: UInt64
        var outputDirectory: String
    }

    private func fixture() throws -> Fixture {
        let path = try #require(Self.fixturePath)
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func samples(at url: URL) throws -> [Float] {
        // Inspect every stored frame of these mono float WAV fixtures. The
        // system decoder can return a shorter tail than the RIFF data chunk.
        let data = try Data(contentsOf: url)
        func uint32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        try #require(data.count >= 12 && String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        var cursor = 12
        var validFormat = false
        while cursor + 8 <= data.count {
            let tag = String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self)
            let length = Int(uint32(cursor + 4)), start = cursor + 8, end = start + length
            try #require(end <= data.count)
            if tag == "fmt ", length >= 16 {
                validFormat = data[start] == 3 && data[start + 2] == 1 && uint32(start + 4) == 24_000 && data[start + 14] == 32
            }
            if tag == "data" {
                try #require(validFormat && length % 4 == 0)
                return stride(from: start, to: end, by: 4).map { Float(bitPattern: uint32($0)) }
            }
            cursor = end + length % 2
        }
        Issue.record("Expected a mono 24 kHz float WAV data chunk")
        return []
    }

    private func verify(_ audio: [Float], segments: [DubRenderedSegment]) throws {
        var levels: [Double] = []
        for segment in segments {
            let start = Int((segment.start * 24_000).rounded()), end = Int((segment.end * 24_000).rounded())
            try #require(start >= 0 && end <= audio.count && end > start, "Range \(start)..<\(end), audio frames \(audio.count)")
            let level = try #require(DubLoudnessNormalizer.integratedLUFS(in: Array(audio[start..<end]), sampleRate: 24_000))
            levels.append(level)
            print("[dub-level] \(segment.speaker ?? "voice") \(segment.start)-\(segment.end)s: \(level) LUFS")
        }
        #expect(levels.count >= 2)
        #expect(try #require(levels.max()) - #require(levels.min()) < 0.2)
        #expect(LinearLoudnessNormalizer.samplePeak(audio) <= 0.8912511)
    }

    @Test(.enabled(if: fixturePath != nil))
    func replayOriginalMultiVoiceSamplesThroughProductionAssembly() throws {
        let fixture = try fixture()
        let original = try samples(at: URL(fileURLWithPath: fixture.originalPath))
        let generated = try fixture.renderedSegments.map { range in
            let start = Int((range.start * 24_000).rounded()), end = Int((range.end * 24_000).rounded())
            try #require(start >= 0 && end <= original.count && end > start, "Range \(start)..<\(end), audio frames \(original.count)")
            return LocalDubFlowRenderer.GeneratedSegment(
                source: .init(index: range.index, text: range.text, start: range.start, speaker: range.speaker),
                samples: Array(original[start..<end])
            )
        }
        let result = LocalDubFlowRenderer.assemble(generated, sampleRate: 24_000, gapSeconds: 0.2)
        #expect(result.samples.count == original.count)
        try verify(result.samples, segments: result.segments)
        let directory = URL(fileURLWithPath: fixture.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(result.samples.count)))
        buffer.frameLength = AVAudioFrameCount(result.samples.count)
        result.samples.withUnsafeBufferPointer { buffer.floatChannelData?[0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("normalized-original.wav"), settings: format.settings)
        try file.write(from: buffer)
    }

    #if BUNDLED_SPEECH
    @Test(.enabled(if: fixturePath != nil && runModel))
    func regenerateMultiVoiceScriptWithOriginalReferences() async throws {
        let fixture = try fixture()
        let payload = DubFlowPayload(
            segments: fixture.segments, language: fixture.language, model: .medium,
            reference: fixture.reference, speakerReferences: [:], segmentReferences: fixture.segmentReferences,
            timelineMode: .audioFlow, seed: fixture.seed
        )
        let result = try await LocalDubFlowRenderer.shared.render(payload: payload) { print("[dub-level-replay] \($0.message)") }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let directory = URL(fileURLWithPath: fixture.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("regenerated.wav")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: result.outputURL, to: destination)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.segments).write(to: directory.appendingPathComponent("regenerated.json"))
        try verify(samples(at: destination), segments: result.segments)
        #expect(result.segments.map(\.speaker) == ["Ad测试", "ABC"])
        #expect(result.segments.first?.start == 0)
        for index in 1..<result.segments.count {
            #expect(abs(result.segments[index].start - result.segments[index - 1].end - 0.2) < 0.0001)
        }
    }
    #endif
}
