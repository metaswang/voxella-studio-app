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
            guard timeRange.start.isValid, timeRange.duration.isValid, timeRange.duration.isNumeric,
                  CMTimeCompare(timeRange.start, assetDuration) < 0 else { continue }
            let end = CMTimeMinimum(CMTimeAdd(timeRange.start, timeRange.duration), assetDuration)
            let duration = CMTimeSubtract(end, timeRange.start)
            guard duration.isValid, duration.isNumeric, duration.seconds > 0 else { continue }
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: timeRange.start, duration: duration),
                of: track,
                at: timeRange.start
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

    @concurrent
    static func concatenate(
        urls: [URL],
        to destinationURL: URL,
        includesVideo: Bool
    ) async throws {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = existing.first else {
            throw MixError(reason: "no segments to concatenate")
        }
        if existing.count == 1 {
            if first != destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: first, to: destinationURL)
            }
            return
        }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for url in existing {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.isNumeric, duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            if includesVideo,
               let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                let compositionVideo = composition.tracks(withMediaType: .video).first as? AVMutableCompositionTrack
                    ?? composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                try compositionVideo?.insertTimeRange(range, of: videoTrack, at: cursor)
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for (index, track) in audioTracks.enumerated() {
                let existingAudio = composition.tracks(withMediaType: .audio)
                let compositionAudio: AVMutableCompositionTrack?
                if index < existingAudio.count {
                    compositionAudio = existingAudio[index] as? AVMutableCompositionTrack
                } else {
                    compositionAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                guard let compositionAudio else { continue }
                try compositionAudio.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor.seconds > 0 else {
            throw MixError(reason: "concatenated duration is empty")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileType = Self.fileType(for: destinationURL, includesVideo: includesVideo)
        let preset = includesVideo || fileType == .mov
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MixError(reason: "export preset unsupported")
        }
        try await session.export(to: destinationURL, as: fileType)
    }

    private static func fileType(for url: URL, includesVideo: Bool) -> AVFileType {
        if includesVideo { return .mp4 }
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        default: return .m4a
        }
    }
}
