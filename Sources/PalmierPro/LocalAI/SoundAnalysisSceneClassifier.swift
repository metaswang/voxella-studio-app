import AVFoundation
import Foundation
import SoundAnalysis

struct SoundAnalysisSceneClassifier: AlignmentSoundSceneClassifying {
    func classifySoundScenes(
        samples: [Float],
        sampleRate: Int,
        ranges: [ClosedRange<Double>]
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

        var windows: [AlignmentSoundSceneWindow] = []
        let windowSeconds = AlignmentSpeechGate.Policy.standard.sceneWindowDuration
        for range in ranges {
            guard range.upperBound > range.lowerBound,
                  range.upperBound - range.lowerBound >= windowSeconds else {
                continue
            }
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(
                seconds: windowSeconds,
                preferredTimescale: CMTimeScale(clamping: sampleRate)
            )
            request.overlapFactor = AlignmentSpeechGate.Policy.standard.sceneOverlapFactor
            let startSample = max(0, Int((range.lowerBound * Double(sampleRate)).rounded(.down)))
            let endSample = min(samples.count, Int((range.upperBound * Double(sampleRate)).rounded(.up)))
            guard endSample > startSample else { continue }
            let slice = Array(samples[startSample..<endSample])
            let observer = SoundSceneObserver(timeOffset: range.lowerBound)
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try withExtendedLifetime(observer) {
                try analyzer.add(request, withObserver: observer)
                analyze(slice: slice, format: format, analyzer: analyzer)
            }
            windows.append(contentsOf: observer.windows())
        }
        return windows
    }

    private func analyze(
        slice: [Float],
        format: AVAudioFormat,
        analyzer: SNAudioStreamAnalyzer
    ) {
        let capacity = AVAudioFrameCount(slice.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channel = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = capacity
        slice.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: slice.count)
        }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
    }
}

private final class SoundSceneObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let timeOffset: Double
    private let lock = NSLock()
    private var collected: [AlignmentSoundSceneWindow] = []

    init(timeOffset: Double) {
        self.timeOffset = timeOffset
    }

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
        let start = timeOffset + result.timeRange.start.seconds
        let end = timeOffset + result.timeRange.end.seconds
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
