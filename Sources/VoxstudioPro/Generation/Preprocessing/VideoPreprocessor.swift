import AVFoundation
import Foundation

enum VideoPreprocessor {
    struct CompressionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Video compression failed: \(reason)" }
    }

    static func downscaleIfNeeded(url: URL, maxLongSide: Int = 1100) async throws -> URL? {
        try await exportIfNeeded(
            url: url, maxLongSide: CGFloat(maxLongSide), maxShortSide: nil,
            preset: AVAssetExportPreset960x540, requiredEncoding: nil
        )
    }

    static func transcodeIfNeeded(
        url: URL,
        maxResolution: SourceVideoResolution?,
        requiredEncoding: SourceVideoEncoding?
    ) async throws -> URL? {
        guard let maxResolution else {
            return try await exportIfNeeded(
                url: url, maxLongSide: nil, maxShortSide: nil,
                preset: AVAssetExportPresetHighestQuality,
                requiredEncoding: requiredEncoding
            )
        }
        let limits: (long: CGFloat, short: CGFloat, preset: String) = switch maxResolution {
        case .p720: (1280, 720, AVAssetExportPreset1280x720)
        case .p1080: (1920, 1080, AVAssetExportPreset1920x1080)
        case .p4k: (3840, 2160, AVAssetExportPreset3840x2160)
        }
        return try await exportIfNeeded(
            url: url, maxLongSide: limits.long, maxShortSide: limits.short,
            preset: limits.preset, requiredEncoding: requiredEncoding
        )
    }

    @concurrent
    private static func exportIfNeeded(
        url: URL,
        maxLongSide: CGFloat?,
        maxShortSide: CGFloat?,
        preset: String,
        requiredEncoding: SourceVideoEncoding?
    ) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = size.applying(transform)
        let longSide = max(abs(display.width), abs(display.height))
        let shortSide = min(abs(display.width), abs(display.height))
        let exceedsResolution = maxLongSide.map { longSide > $0 } == true
            || maxShortSide.map { shortSide > $0 } == true
        let requiresEncoding = switch requiredEncoding {
        case .h264MP4:
            try await !isH264MP4(url: url, track: track)
        case nil:
            false
        }
        guard exceedsResolution || requiresEncoding else { return nil }

        let exportPreset = exceedsResolution ? preset : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            throw CompressionError(reason: "export preset unsupported")
        }
        if exceedsResolution, let maxLongSide {
            let scale = min(maxLongSide / longSide, (maxShortSide ?? maxLongSide) / shortSide)
            let renderSize = CGSize(
                width: max(2, floor(abs(display.width) * scale / 2) * 2),
                height: max(2, floor(abs(display.height) * scale / 2) * 2)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.enablePostProcessing = false
            instruction.layerInstructions = [layer]
            instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let videoComposition = AVMutableVideoComposition()
            let nominalFrameRate = try await track.load(.nominalFrameRate)
            let frameRate: Int32
            if nominalFrameRate.isFinite,
               nominalFrameRate > 0,
               nominalFrameRate <= Float(Int32.max) {
                frameRate = max(1, Int32(nominalFrameRate.rounded()))
            } else {
                frameRate = 30
            }
            videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
            videoComposition.renderSize = renderSize
            videoComposition.instructions = [instruction]
            session.videoComposition = videoComposition
        }
        let outputURL = FileIO.temporaryFileURL(pathExtension: "mp4")
        do {
            try await session.export(to: outputURL, as: .mp4)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func isH264MP4(url: URL, track: AVAssetTrack) async throws -> Bool {
        guard url.pathExtension.lowercased() == "mp4" else { return false }
        let descriptions = try await track.load(.formatDescriptions)
        return !descriptions.isEmpty && descriptions.allSatisfy {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
        }
    }
}
