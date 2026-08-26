import AVFoundation
import CoreMedia
import Foundation

enum RecordingAudioMixer {
    struct MixError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Could not mix recorded audio: \(reason)" }
    }

    @concurrent
    static func mixToSingleAudioTrack(
        from sourceURL: URL,
        to destinationURL: URL,
        includesVideo: Bool
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard audioTracks.count >= 2 else {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return
        }

        let composition = AVMutableComposition()
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        if includesVideo, let videoTrack = videoTracks.first,
           let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await asset.load(.duration)
            try compositionVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: .zero
            )
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        let assetDuration = try await asset.load(.duration)
        for track in audioTracks {
            guard let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let timeRange = try await track.load(.timeRange)
            let duration = CMTimeMinimum(timeRange.duration, assetDuration)
            guard duration.isValid, duration.isNumeric, duration.seconds > 0 else { continue }
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: timeRange.start, duration: duration),
                of: track,
                at: .zero
            )
            let parameters = AVMutableAudioMixInputParameters(track: compositionAudio)
            parameters.setVolume(1, at: .zero)
            audioMixParameters.append(parameters)
        }
        guard !audioMixParameters.isEmpty else {
            throw MixError(reason: "no mixable audio tracks")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let preset = includesVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        let fileType: AVFileType = includesVideo ? .mp4 : .m4a
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MixError(reason: "export preset unsupported")
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParameters
        session.audioMix = audioMix
        try await session.export(to: destinationURL, as: fileType)
    }
}
