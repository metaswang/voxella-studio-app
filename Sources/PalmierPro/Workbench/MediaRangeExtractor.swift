import AVFoundation
import Foundation

/// Exports a wall-clock media window to a durable temp/workbench file.
enum MediaRangeExtractor {
    struct ExtractionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Clip extraction failed: \(reason)" }
    }

    /// Returns a new file containing `[range.lowerBound, range.upperBound)` of `sourceURL`.
    static func extract(
        sourceURL: URL,
        range: ClosedRange<Double>,
        destinationURL: URL
    ) async throws {
        let start = range.lowerBound
        let end = range.upperBound
        guard start.isFinite, end.isFinite, end > start else {
            throw ExtractionError(reason: "invalid range")
        }

        let asset = AVURLAsset(url: sourceURL)
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        guard hasVideo || hasAudio else {
            throw ExtractionError(reason: "no audio or video tracks")
        }

        let composition = AVMutableComposition()
        let timescale: CMTimeScale = 600
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: end - start, preferredTimescale: timescale)
        )

        if hasVideo,
           let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compVideo.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        if hasAudio,
           let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudio.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let presetName = hasVideo
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExtractionError(reason: "export preset unsupported")
        }
        let fileType: AVFileType = hasVideo ? .mp4 : .m4a
        try await session.export(to: destinationURL, as: fileType)
    }
}
