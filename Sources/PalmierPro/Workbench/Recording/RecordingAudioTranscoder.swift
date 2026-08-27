import AVFoundation
import CoreMedia
import Foundation

final class RecordingAudioTranscoder: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2

    static let canonicalFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            preconditionFailure("Canonical recording audio format is unavailable.")
        }
        return format
    }()

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pts = CMTime.zero
    private var didLogInputFormat = false

    func reset() {
        converter = nil
        converterInputFormat = nil
        pts = .zero
        didLogInputFormat = false
    }

    func transcode(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let input = Self.pcmBuffer(from: sampleBuffer),
              let converted = resample(input) else {
            return nil
        }
        guard let output = Self.makeSampleBuffer(from: converted, presentationTime: pts) else {
            return nil
        }
        let duration = CMTime(
            value: CMTimeValue(converted.frameLength),
            timescale: CMTimeScale(Self.sampleRate)
        )
        pts = CMTimeAdd(pts, duration)
        return output
    }

    func resample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = input.format
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0, input.frameLength > 0 else {
            return nil
        }
        if !didLogInputFormat {
            didLogInputFormat = true
            Log.recording.notice(
                "recording audio input rate=\(inFormat.sampleRate) channels=\(inFormat.channelCount) interleaved=\(inFormat.isInterleaved) common=\(Self.commonFormatName(inFormat.commonFormat))"
            )
        }
        if Self.matchesCanonical(inFormat) {
            return input
        }
        if converter == nil || converterInputFormat.map({ !Self.isSameFormat($0, inFormat) }) == true {
            converter = AVAudioConverter(from: inFormat, to: Self.canonicalFormat)
            converterInputFormat = inFormat
            guard converter != nil else {
                Log.recording.error(
                    "recording audio converter unavailable rate=\(inFormat.sampleRate) channels=\(inFormat.channelCount)"
                )
                return nil
            }
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 8_192)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: capacity) else {
            return nil
        }

        let supplier = ConversionInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            supplier.next(status: status)
        }
        guard conversionError == nil, status != .error, output.frameLength > 0 else {
            Log.recording.error(
                "recording audio conversion failed status=\(String(describing: status)) error=\(conversionError?.localizedDescription ?? "nil")"
            )
            return nil
        }
        return output
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        ) == noErr else {
            return nil
        }
        return pcm
    }

    static func makeSilentSampleBuffer(
        frameCount: AVAudioFrameCount = 2_048,
        presentationTime: CMTime = .zero
    ) -> CMSampleBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(frameCount))
            }
        }
        return makeSampleBuffer(from: buffer, presentationTime: presentationTime)
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let format = buffer.format
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        let frameCount = CMItemCount(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: buffer.audioBufferList
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func matchesCanonical(_ format: AVAudioFormat) -> Bool {
        isSameFormat(format, canonicalFormat)
    }

    private static func isSameFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func commonFormatName(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: "float32"
        case .pcmFormatFloat64: "float64"
        case .pcmFormatInt16: "int16"
        case .pcmFormatInt32: "int32"
        default: "other"
        }
    }
}

private final class ConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
