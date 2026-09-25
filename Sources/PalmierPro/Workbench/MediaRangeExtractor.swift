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

        let assetDuration = try await asset.load(.duration).seconds
        let clippedEnd = assetDuration.isFinite && assetDuration > 0 ? min(end, assetDuration) : end
        guard clippedEnd > start else {
            throw ExtractionError(reason: "range starts after the media ends")
        }
        let timescale: CMTimeScale = 600
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: clippedEnd - start, preferredTimescale: timescale)
        )

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileType: AVFileType = hasVideo ? .mp4 : .m4a
        do {
            // Copy compressed tracks first. Video boundaries may land on nearby keyframes.
            try await export(asset, range: timeRange, preset: AVAssetExportPresetPassthrough,
                             fileType: fileType, to: destinationURL)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destinationURL)
            let fallback = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
            do {
                try await export(asset, range: timeRange, preset: fallback,
                                 fileType: fileType, to: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    private static func export(
        _ asset: AVURLAsset,
        range: CMTimeRange,
        preset: String,
        fileType: AVFileType,
        to destinationURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExtractionError(reason: "export preset unsupported")
        }
        session.timeRange = range
        try await session.export(to: destinationURL, as: fileType)
    }
}
