import AVFoundation
import Foundation
import SoundAnalysis

struct SoundAnalysisSceneClassifier: AlignmentSoundSceneClassifying {
    private static let maximumInputDuration = 15.0

    func classifySoundScenes(
        samples: [Float],
        sampleRate: Int,
        ranges: [ClosedRange<Double>],
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> [AlignmentSoundSceneWindow] {
        guard sampleRate > 0, !samples.isEmpty, !ranges.isEmpty else { return [] }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            return []
        }

        let windowSeconds = AlignmentSpeechGate.Policy.standard.sceneWindowDuration
        let buffers = inputBuffers(
            ranges: ranges,
            sampleCount: samples.count,
            sampleRate: sampleRate,
            minimumDuration: windowSeconds
        )
        guard !buffers.isEmpty else { return [] }

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(
            seconds: windowSeconds,
            preferredTimescale: CMTimeScale(clamping: sampleRate)
        )
        request.overlapFactor = AlignmentSpeechGate.Policy.standard.sceneOverlapFactor
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = SoundSceneObserver()
        progress(0, buffers.count)
        try withExtendedLifetime(observer) {
            try analyzer.add(request, withObserver: observer)
            try analyze(
                samples: samples,
                buffers: buffers,
                format: format,
                analyzer: analyzer,
                progress: progress
            )
        }
        return observer.windows()
    }

    private func analyze(
        samples: [Float],
        buffers: [InputBuffer],
        format: AVAudioFormat,
        analyzer: SNAudioStreamAnalyzer,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws {
        guard let largestBuffer = buffers.map(\.sampleCount).max() else { return }
        let capacity = AVAudioFrameCount(largestBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channel = buffer.floatChannelData?[0] else {
            return
        }
        for (index, input) in buffers.enumerated() {
            try Task.checkCancellation()
            buffer.frameLength = AVAudioFrameCount(input.sampleCount)
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel.update(from: base.advanced(by: input.startSample), count: input.sampleCount)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(input.startSample))
            progress(index + 1, buffers.count)
        }
        analyzer.completeAnalysis()
    }

    private func inputBuffers(
        ranges: [ClosedRange<Double>],
        sampleCount: Int,
        sampleRate: Int,
        minimumDuration: Double
    ) -> [InputBuffer] {
        let audioDuration = Double(sampleCount) / Double(sampleRate)
        let maximumBufferDuration = min(Self.maximumInputDuration, audioDuration)
        let maximumBufferSamples = min(
            sampleCount,
            max(1, Int((maximumBufferDuration * Double(sampleRate)).rounded(.down)))
        )
        let minimumSamples = max(1, Int((minimumDuration * Double(sampleRate)).rounded(.up)))
        var buffers: [InputBuffer] = []

        for range in ranges {
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.upperBound > range.lowerBound else {
                continue
            }
            let startTime = min(audioDuration, max(0, range.lowerBound))
            let endTime = min(audioDuration, max(0, range.upperBound))
            guard endTime > startTime else { continue }
            let start = min(
                sampleCount,
                max(0, Int((startTime * Double(sampleRate)).rounded(.down)))
            )
            let end = min(
                sampleCount,
                max(0, Int((endTime * Double(sampleRate)).rounded(.up)))
            )
            guard end - start >= minimumSamples else { continue }
            var current = start
            while current < end {
                let count = min(maximumBufferSamples, end - current)
                buffers.append(InputBuffer(startSample: current, sampleCount: count))
                current += count
            }
        }
        return buffers
    }

    private struct InputBuffer: Sendable {
        let startSample: Int
        let sampleCount: Int
    }
}

private final class SoundSceneObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [AlignmentSoundSceneWindow] = []

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let classifications = result.classifications
        guard let top = classifications.max(by: { $0.confidence < $1.confidence }) else { return }
        let speechConfidence = classifications.reduce(0.0) { partial, item in
            AlignmentSpeechGate.isSpeechLabel(item.identifier)
                ? max(partial, Double(item.confidence))
                : partial
        }
        let musicConfidence = classifications.reduce(0.0) { partial, item in
            AlignmentSpeechGate.isMusicOrSinging(item.identifier)
                ? max(partial, Double(item.confidence))
                : partial
        }
        let start = result.timeRange.start.seconds
        let end = result.timeRange.end.seconds
        let window = AlignmentSoundSceneWindow(
            startTime: start,
            endTime: end,
            speechConfidence: speechConfidence,
            musicOrSingingConfidence: musicConfidence,
            topLabel: top.identifier,
            topConfidence: Double(top.confidence)
        )
        lock.lock()
        collected.append(window)
        lock.unlock()
    }

    func windows() -> [AlignmentSoundSceneWindow] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
