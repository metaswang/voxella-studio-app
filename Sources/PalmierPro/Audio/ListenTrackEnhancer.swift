import AVFoundation
import Foundation

#if BUNDLED_SPEECH
import SpeechEnhancement
#endif

/// Post-record listen-track bake: HPF → DeepFilterNet3 → OA blend → linear loudness → true-peak.
/// Never used as the ASR input; master remains source of truth for transcription.
enum ListenTrackEnhancer {
    static let cache = DiskCache(named: "ListenTrackAudio")

    enum EnhanceError: LocalizedError {
        case noAudioTrack
        case writeFailed
        case disabled

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "Source has no audio track"
            case .writeFailed: "Could not write listen track"
            case .disabled: "Listen enhance is disabled"
            }
        }
    }

    struct Result: Sendable {
        var listenURL: URL
        var fromCache: Bool
    }

    /// Returns a ready listen file beside/cached for `masterURL`, baking if needed.
    static func enhance(
        masterURL: URL,
        wetMix: Float = ListenEnhanceSettings.defaultWetMix,
        force: Bool = false
    ) async throws -> Result {
        guard ListenEnhanceSettings.isEnabled else { throw EnhanceError.disabled }

        if !force, let existing = ListenTrackLocator.existingListenURL(forMaster: masterURL) {
            return Result(listenURL: existing, fromCache: true)
        }

        let outputURL = ListenTrackLocator.sidecarURL(forMaster: masterURL)
        #if BUNDLED_SPEECH
        let start = ContinuousClock.now
        let dryChannels = try await readChannels(from: masterURL)
        guard dryChannels.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }

        var wetChannels: [[Float]] = []
        wetChannels.reserveCapacity(dryChannels.count)
        for channel in dryChannels {
            let filtered = LinearLoudnessNormalizer.highPass(
                channel,
                sampleRate: sampleRate,
                cutoffHz: ListenEnhanceSettings.highPassCutoffHz
            )
            let denoised = try await modelBox.enhance(audio: filtered, sampleRate: Int(sampleRate))
            let blended = VoiceReferenceSpeechGate.mix(
                dry: filtered,
                wet: denoised,
                wetMix: wetMix
            )
            let normalized = LinearLoudnessNormalizer.normalizeLinear(
                blended,
                targetLUFS: ListenEnhanceSettings.targetIntegratedLUFS,
                truePeakCeilingDBTP: ListenEnhanceSettings.truePeakCeilingDBTP
            )
            wetChannels.append(normalized)
        }

        try writeAAC(channels: wetChannels, to: outputURL)
        // Mirror into size/mtime cache so replace/invalidation stays coherent with AudioEnhancer.
        let cached = ListenTrackLocator.cacheURL(forMaster: masterURL)
        try? FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileIO.copyReplacingDestination(from: outputURL, to: cached)

        let elapsedSeconds = Double(start.duration(to: .now).components.seconds)
        let wetLabel = String(format: "%.2f", wetMix)
        let secondsLabel = String(format: "%.1f", elapsedSeconds)
        Log.recording.notice(
            "listen enhance ok master=\(masterURL.lastPathComponent) wetMix=\(wetLabel) seconds=\(secondsLabel)"
        )
        return Result(listenURL: outputURL, fromCache: false)
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    #if BUNDLED_SPEECH
    private static let modelBox = ModelBox()
    private static var sampleRate: Double { Double(SpeechEnhancer.sampleRate) }

    private actor ModelBox {
        private var enhancer: SpeechEnhancer?

        func enhance(audio: [Float], sampleRate: Int) async throws -> [Float] {
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            if enhancer == nil { enhancer = try await SpeechEnhancer.fromPretrained() }
            // speech-swift DeepFilterNet3 has no public post-filter toggle; keep default enhance
            // and rely on a conservative OA wet mix for hall recordings.
            return try enhancer!.enhanceChunked(audio: audio, sampleRate: sampleRate)
        }
    }

    private static func readChannels(from url: URL) async throws -> [[Float]] {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let desc = try await track?.load(.formatDescriptions).first
        let sourceChannels = desc.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        } ?? 1
        let count = min(2, max(1, Int(sourceChannels)))
        var channels = [[Float]](repeating: [], count: count)
        try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: count,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ]
        ) { buffer in
            guard let data = buffer.floatChannelData else { return }
            for ch in 0..<count {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
        }
        return channels
    }

    private static func writeAAC(channels: [[Float]], to outputURL: URL) throws {
        guard let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount }) else {
            throw EnhanceError.writeFailed
        }
        let channelCount = AVAudioChannelCount(channels.count)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ),
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw EnhanceError.writeFailed }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        for ch in channels.indices {
            channels[ch].withUnsafeBufferPointer { src in
                pcmBuffer.floatChannelData?[ch].update(from: src.baseAddress!, count: frameCount)
            }
        }

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".writing-listen-\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: tempURL, settings: settings)
        try file.write(from: pcmBuffer)
        try FileIO.moveReplacingDestination(from: tempURL, to: outputURL)
    }
    #endif
}
