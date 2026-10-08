import AVFoundation
import Foundation
import Testing
@testable import WeSpeakerEmbedding

/// Real-weight checks, enabled when WESPEAKER_MODEL_DIR and WESPEAKER_AUDIO_DIR are set.
@Suite struct WeSpeakerModelTests {
    static let modelDirectory = ProcessInfo.processInfo.environment["WESPEAKER_MODEL_DIR"]
    static let audioDirectory = ProcessInfo.processInfo.environment["WESPEAKER_AUDIO_DIR"]

    static func samples(_ name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioDirectory!).appendingPathComponent(name))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    @Test(.enabled(if: modelDirectory != nil && audioDirectory != nil))
    func sameSpeakerScoresAboveDifferentSpeakers() throws {
        let embedder = try WeSpeakerEmbedder(modelDirectory: URL(fileURLWithPath: Self.modelDirectory!))
        let english = try Self.samples("en-single.wav")
        let chinese = try Self.samples("zh-single.wav")
        let half = english.count / 2
        let a = try embedder.embed(Array(english[..<half]))
        let b = try embedder.embed(Array(english[half...]))
        let c = try embedder.embed(chinese)
        let same = Self.cosine(a, b)
        let different = max(Self.cosine(a, c), Self.cosine(b, c))
        print("WESPEAKER same=\(same) different=\(different)")
        #expect(abs(a.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
        #expect(same > different)
        #expect(throws: WeSpeakerEmbeddingError.self) { _ = try embedder.embed([Float](repeating: 0.1, count: 100)) }
        #expect(throws: WeSpeakerEmbeddingError.invalidAudio) {
            _ = try embedder.embed([Float](repeating: .nan, count: 16_000))
        }
    }
}
