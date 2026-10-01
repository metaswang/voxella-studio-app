import AVFoundation
import CoreMedia
import Foundation

struct RecordingTrackProgress: Equatable, Sendable {
    var lastReceivedUptime: TimeInterval = 0
    var lastAppendedUptime: TimeInterval = 0
    var lastReceivedPTS: Double?
    var lastCommittedPTS: Double?
    var dropped = 0
    var failedAppends = 0
    var conversionFailures = 0
    var committedFrames: Int64 = 0
    var receivedSamples: Int64 = 0

    mutating func noteReceived(at uptime: TimeInterval, pts: CMTime?) {
        lastReceivedUptime = uptime
        receivedSamples += 1
        if let pts, pts.isNumeric {
            lastReceivedPTS = pts.seconds
        }
    }

    mutating func noteCommitted(at uptime: TimeInterval, pts: CMTime, frames: Int64) {
        lastAppendedUptime = uptime
        committedFrames += frames
        if pts.isNumeric {
            lastCommittedPTS = pts.seconds
        }
    }
}

struct RecordingAudioCursor: Equatable, Sendable {
    var nextPTS: CMTime?

    mutating func plan(samplePTS: CMTime, gapThreshold: TimeInterval) -> (silenceFrom: CMTime?, commitPTS: CMTime) {
        guard let next = nextPTS else {
            return (nil, samplePTS)
        }
        let gap = CMTimeSubtract(samplePTS, next)
        if gap.isNumeric, gap.seconds >= gapThreshold {
            return (next, samplePTS)
        }
        return (nil, next)
    }

    mutating func commit(start: CMTime, frames: Int64, sampleRate: Double) {
        let timescale = CMTimeScale(max(1, sampleRate.rounded()))
        let duration = CMTime(value: CMTimeValue(max(frames, 0)), timescale: timescale)
        nextPTS = CMTimeAdd(start, duration)
    }
}

struct RecordingHealthMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case starting
        case restarting
        case awaitingSamples
        case healthy
        case failed
    }

    enum Decision: Equatable, Sendable {
        case none
        case restartCapture(String)
        case rolloverWriter(String)
        case rebuildConverter(String)
        case fail(String)
    }

    var phase: Phase = .starting
    var lastReceived: TimeInterval = 0
    var lastAppended: TimeInterval = 0
    var lastConverted: TimeInterval = 0
    var failureDeadline: TimeInterval?
    var stallBeganAt: TimeInterval?
    var writerNotReadySince: TimeInterval?
    var consecutiveGoodSamples = 0
    var restartCount = 0
    var conversionFailures = 0
    var dropped = 0
    var failedAppends = 0

    mutating func reset(at uptime: TimeInterval) {
        self = RecordingHealthMachine()
        phase = .starting
        _ = uptime
    }

    mutating func applyPauseGrace(duration: TimeInterval) {
        if let deadline = failureDeadline {
            failureDeadline = deadline + duration
        }
        stallBeganAt = nil
        writerNotReadySince = nil
    }

    mutating func noteRestartAttempt(at uptime: TimeInterval) {
        phase = .awaitingSamples
        restartCount += 1
        consecutiveGoodSamples = 0
        if failureDeadline == nil {
            failureDeadline = uptime + RecordingCaptureHealth.failureTimeout
        }
    }

    mutating func noteReceived(at uptime: TimeInterval) {
        lastReceived = uptime
        consecutiveGoodSamples += 1
        if consecutiveGoodSamples >= RecordingCaptureHealth.recoveredSampleCount {
            phase = .healthy
            failureDeadline = nil
            stallBeganAt = nil
        } else if phase != .failed {
            phase = .awaitingSamples
        }
    }

    mutating func noteConverted(at uptime: TimeInterval) {
        lastConverted = uptime
    }

    mutating func noteCommitted(at uptime: TimeInterval) {
        lastAppended = uptime
        writerNotReadySince = nil
    }

    mutating func noteWriterNotReady(at uptime: TimeInterval) {
        dropped += 1
        if writerNotReadySince == nil {
            writerNotReadySince = uptime
        }
    }

    mutating func noteConversionFailure() {
        conversionFailures += 1
    }

    mutating func noteAppendFailure() {
        failedAppends += 1
    }

    mutating func evaluate(
        at now: TimeInterval,
        startedAt: TimeInterval,
        enabled: Bool,
        allowsIdleSource: Bool = false
    ) -> Decision {
        guard enabled, phase != .failed else { return .none }
        guard now - startedAt > RecordingCaptureHealth.startupGrace else { return .none }

        // iOS sends device audio only while sound is playing. Silence is not a
        // broken capture session; disconnects and video health are monitored separately.
        let hasRecentSamples = lastReceived > 0 && now - lastReceived <= RecordingCaptureHealth.stallTimeout
        if allowsIdleSource, !hasRecentSamples {
            failureDeadline = nil
            stallBeganAt = nil
            return .none
        }

        if let deadline = failureDeadline, now >= deadline {
            if !hasRecentSamples {
                phase = .failed
                return .fail("no samples before deadline")
            }
        }

        if lastReceived > 0,
           now - lastReceived <= RecordingCaptureHealth.stallTimeout,
           let notReady = writerNotReadySince,
           now - notReady >= RecordingCaptureHealth.writerBackpressureTimeout {
            return .rolloverWriter("writer backpressure")
        }

        let receiptStalled = lastReceived == 0 || now - lastReceived > RecordingCaptureHealth.stallTimeout
        let conversionStalled = lastConverted == 0 || now - lastConverted > RecordingCaptureHealth.stallTimeout
        let writeStalled = lastAppended == 0 || now - lastAppended > RecordingCaptureHealth.stallTimeout

        if receiptStalled {
            if stallBeganAt == nil {
                stallBeganAt = now
                if failureDeadline == nil {
                    failureDeadline = now + RecordingCaptureHealth.failureTimeout
                }
                return .restartCapture("receipt stall")
            }
            if now - (stallBeganAt ?? now) >= RecordingCaptureHealth.failureTimeout {
                phase = .failed
                return .fail("receipt stall timeout")
            }
            return .none
        }

        if conversionStalled && !receiptStalled {
            if conversionFailures > 0 {
                return .rebuildConverter("conversion stall")
            }
        }

        if writeStalled && !receiptStalled {
            if stallBeganAt == nil {
                stallBeganAt = now
                return .rolloverWriter("write stall")
            }
            if now - (stallBeganAt ?? now) >= RecordingCaptureHealth.failureTimeout {
                phase = .failed
                return .fail("write stall timeout")
            }
            return .rolloverWriter("write stall")
        }

        stallBeganAt = nil
        if phase == .healthy {
            failureDeadline = nil
        }
        return .none
    }
}

struct RecordingWriterSegment: Equatable, Sendable {
    var index: Int
    var url: URL
    var globalStart: Double
    var localDuration: Double?
    var status: String
    var didAppendMedia: Bool
    var didAppendVideo: Bool
    var didAppendMicrophone: Bool
    var didAppendSystemAudio: Bool

    var journalSegment: RecordingJournalSegment {
        RecordingJournalSegment(
            index: index,
            path: url.path,
            globalStart: globalStart,
            localDuration: localDuration,
            status: status,
            didAppendMedia: didAppendMedia,
            didAppendVideo: didAppendVideo,
            didAppendMicrophone: didAppendMicrophone,
            didAppendSystemAudio: didAppendSystemAudio
        )
    }
}

enum RecordingFinishMode: Equatable, Sendable {
    case export
    case salvage
    case discard
}

struct RecordingHealthSnapshot: Equatable, Sendable {
    var sessionID: UUID?
    var isStopping = true
    var isHealthy = false
    var failureDeadline: TimeInterval?
    var lastReceived: TimeInterval = 0
    var lastAppended: TimeInterval = 0
}

final class RecordingFinishContext: @unchecked Sendable {
    let sessionID: UUID
    let operationID: UUID
    let captureGeneration: UInt64
    let mode: RecordingFinishMode
    let writer: AVAssetWriter?
    let outputURL: URL?
    let includesVideo: Bool
    let audioTrackCount: Int
    let didAppendMedia: Bool
    let didAppendVideo: Bool
    let didAppendMicrophone: Bool
    let didAppendSystemAudio: Bool
    let segments: [RecordingWriterSegment]
    let diagnostics: RecordingSessionDiagnostics
    let stopReason: RecordingStopReason
    let gate = RecordingOnceGate<RecordingStopResult>()

    private let lock = NSLock()
    private var didFinalizeWriter = false
    private var streamStopWorkItem: DispatchWorkItem?
    private var writerFinishWorkItem: DispatchWorkItem?

    init(
        sessionID: UUID,
        operationID: UUID,
        captureGeneration: UInt64,
        mode: RecordingFinishMode,
        writer: AVAssetWriter?,
        outputURL: URL?,
        includesVideo: Bool,
        audioTrackCount: Int,
        didAppendMedia: Bool,
        didAppendVideo: Bool,
        didAppendMicrophone: Bool,
        didAppendSystemAudio: Bool,
        segments: [RecordingWriterSegment],
        diagnostics: RecordingSessionDiagnostics,
        stopReason: RecordingStopReason
    ) {
        self.sessionID = sessionID
        self.operationID = operationID
        self.captureGeneration = captureGeneration
        self.mode = mode
        self.writer = writer
        self.outputURL = outputURL
        self.includesVideo = includesVideo
        self.audioTrackCount = audioTrackCount
        self.didAppendMedia = didAppendMedia
        self.didAppendVideo = didAppendVideo
        self.didAppendMicrophone = didAppendMicrophone
        self.didAppendSystemAudio = didAppendSystemAudio
        self.segments = segments
        self.diagnostics = diagnostics
        self.stopReason = stopReason
    }

    func matches(sessionID: UUID, operationID: UUID) -> Bool {
        self.sessionID == sessionID && self.operationID == operationID
    }

    func markWriterFinalized() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didFinalizeWriter { return false }
        didFinalizeWriter = true
        return true
    }

    func storeStreamTimeout(_ work: DispatchWorkItem) {
        lock.lock()
        streamStopWorkItem = work
        lock.unlock()
    }

    func storeWriterTimeout(_ work: DispatchWorkItem) {
        lock.lock()
        writerFinishWorkItem = work
        lock.unlock()
    }

    func invalidateTimeouts() {
        lock.lock()
        streamStopWorkItem?.cancel()
        writerFinishWorkItem?.cancel()
        streamStopWorkItem = nil
        writerFinishWorkItem = nil
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: Result<RecordingStopResult, Error>) -> Bool {
        invalidateTimeouts()
        return gate.resume(result)
    }
}

struct MicrophoneCapturedSample {
    let sessionID: UUID
    let backendGeneration: UInt64
    let sampleBuffer: CMSampleBuffer
    let capturePTS: CMTime
}
