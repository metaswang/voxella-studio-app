import AVFoundation
import Foundation

enum SpeechInputAudio {
    @concurrent
    static func samples(
        from sourceURL: URL,
        sampleRate: Int = ASRAudioPreprocessor.sampleRate,
        range: ClosedRange<Double>? = nil,
        maximumDuration: Double? = SpeechInputResult.maximumDuration
    ) async throws -> [Float] {
        try Task.checkCancellation()
        guard (1...192_000).contains(sampleRate) else { throw SpeechInputError.invalidAudioFormat }
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0 else {
                throw SpeechInputError.invalidAudioFormat
            }
        }
        var samples: [Float] = []
        let limit = maximumDuration.map { Int($0 * Double(sampleRate)) } ?? .max
        if limit != .max { samples.reserveCapacity(limit) }
        try await AudioTrackReader.read(
            from: sourceURL,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ],
            range: range ?? maximumDuration.map { 0...$0 }
        ) { buffer in
            try Task.checkCancellation()
            guard let channel = buffer.floatChannelData?[0] else { throw LocalAIError.noAudioSamples }
            let count = min(Int(buffer.frameLength), limit - samples.count)
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        try Task.checkCancellation()
        return samples
    }
}
