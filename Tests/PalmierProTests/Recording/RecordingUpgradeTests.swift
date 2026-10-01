@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PalmierPro

@Suite("Recording upgrades")
struct RecordingUpgradeTests {
    @Test func mobileUsesDeviceAudioWithoutScreenPermission() {
        var configuration = RecordingCaptureConfiguration()
        configuration.applyMode(.mobileDevice)
        #expect(configuration.microphone == .off)
        #expect(configuration.capturesDeviceAudio)
        #expect(configuration.hasAudioSource)
        #expect(!configuration.requiresScreenCapture)
        #expect(!configuration.requiresScreenCapturePermissionRequest)
        configuration.capturesDeviceAudio = false
        configuration.normalizeAudioSources()
        #expect(!configuration.hasAudioSource)
        #expect(configuration.hasCaptureSource)
        #expect(configuration.microphone == .off)
        #expect(RecordingError.cameraDenied.permissionKind == .camera)
    }

    @Test func silentScreenVideoDoesNotTurnAudioBackOn() {
        var configuration = RecordingCaptureConfiguration(mode: .region, microphone: .off, capturesSystemAudio: false)
        configuration.normalizeAudioSources()
        #expect(configuration.hasCaptureSource)
        #expect(!configuration.hasAudioSource)
        #expect(configuration.microphone == .off)
    }

    @Test func videoDimensionsPreserveOrientationAndDoNotUpscale() {
        var settings = RecordingVideoSettings()
        settings.resolution = .fullHD
        let landscape = settings.outputSize(for: CGSize(width: 3840, height: 2160))
        #expect(landscape.width == 1920 && landscape.height == 1080)
        let portrait = settings.outputSize(for: CGSize(width: 2160, height: 3840))
        #expect(portrait.width == 1080 && portrait.height == 1920)
        let small = settings.outputSize(for: CGSize(width: 501, height: 301))
        #expect(small.width == 500 && small.height == 300)
        settings.frameRate = 120
        #expect(settings.effectiveFrameRate == 30)
        settings.frameRate = 60
        #expect(settings.effectiveFrameRate == 60)
    }

    @Test func settingsRoundTrip() throws {
        let name = "recording-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = RecordingVideoSettings()
        settings.resolution = .hd
        settings.frameRate = 15
        settings.showsCursor = false
        settings.quality = .low
        settings.save(defaults: defaults)
        #expect(RecordingVideoSettings.load(defaults: defaults) == settings)
    }

    @Test func successfulTrimCommitsBeforeRemovingSourceAndSegments() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source, includesAudio: true)
        let segment = directory.appendingPathComponent("recording-seg1.mov")
        try Data("old segment".utf8).write(to: segment)
        let id = UUID()
        let result = RecordingStopResult(url: source, diagnostics: .init(microphone: nil, systemAudio: nil),
                                         segmentURLs: [segment], sessionID: id)
        try RecordingTrimTransaction.markForReview(result)
        let output = try await RecordingTrimTransaction.commit(result: result, range: 1.2...3.2)
        let inspection = await RecordingMediaValidator.inspect(output)
        #expect(inspection.isReadable && inspection.hasVideo && inspection.hasAudio)
        #expect(abs(try #require(inspection.duration) - 2) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: segment.path))
        let recovered = RecordingSessionManifest.recoverInterruptedSessions(in: directory)
        #expect(recovered.count == 1)
        #expect(recovered.first?.urls == [output])
        #expect(recovered.first?.manifest.trimStart == 1.2)
        RecordingSessionManifest.markRegistered(sessionID: id.uuidString, in: directory)
        #expect(RecordingSessionManifest.recoverInterruptedSessions(in: directory).isEmpty)
    }

    @Test func failedTrimKeepsRecoverableOriginal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source, includesAudio: false)
        let result = RecordingStopResult(url: source, diagnostics: .init(microphone: nil, systemAudio: nil), sessionID: UUID())
        await #expect(throws: (any Error).self) {
            _ = try await RecordingTrimTransaction.commit(result: result, range: 9...10)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let inspection = await RecordingMediaValidator.inspect(source)
        #expect(inspection.isReadable && inspection.hasVideo && !inspection.hasAudio)
        let recovered = RecordingSessionManifest.recoverInterruptedSessions(in: directory)
        #expect(recovered.first?.urls == [source])
        #expect(recovered.first?.status == RecordingSessionManifest.pendingTrim)
    }

    @Test func cleanupCannotDeleteOutsideSessionDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("trimmed.mp4")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("unrelated-\(UUID()).mp4")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        var journal = RecordingSessionManifest(sessionID: UUID().uuidString, startedAt: Date(), outputPath: output.path,
                                               mode: "display", backend: "stream", status: RecordingSessionManifest.pendingReview)
        journal.trimDiscardPaths = [outside.path, output.path]
        RecordingTrimTransaction.cleanupCommittedOriginals(journal)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A real five-second H.264/AAC fixture checks the exporter and journal together.
    private func makeVideo(at url: URL, includesAudio: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 60, AVVideoAllowFrameReorderingKey: false],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        audio.expectsMediaDataInRealTime = true
        if includesAudio { writer.add(audio) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        for frame in 0..<150 {
            let deadline = Date().addingTimeInterval(5)
            while !video.isReadyForMoreMediaData {
                guard Date() < deadline else { throw RecordingError.writerFailed("Fixture video encoder timed out") }
                if writer.status == .failed { throw try #require(writer.error) }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, try #require(adaptor.pixelBufferPool), &pixel)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 255 / 150), CVPixelBufferGetBytesPerRow(buffer) * 120)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: Int64(frame), timescale: 30)
            #expect(adaptor.append(buffer, withPresentationTime: pts))
            if includesAudio {
                while !audio.isReadyForMoreMediaData {
                    guard Date() < deadline else { throw RecordingError.writerFailed("Fixture audio encoder timed out") }
                    if writer.status == .failed { throw try #require(writer.error) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
                pcm.frameLength = 1600
                for index in 0..<1600 { pcm.floatChannelData?[0][index] = Float(sin(Double(frame * 1600 + index) * 2 * .pi * 440 / 48000)) * 0.1 }
                let sample = try #require(RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: pts))
                #expect(audio.append(sample))
            }
        }
        video.markAsFinished()
        if includesAudio { audio.markAsFinished() }
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
