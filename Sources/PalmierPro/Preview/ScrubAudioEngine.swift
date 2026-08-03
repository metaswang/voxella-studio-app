import AppKit
import AVFoundation

@MainActor
final class ScrubAudioEngine {
    private enum Direction: Sendable {
        case forward
        case reverse
    }

    // Safety: asset and mix are never mutated here; AVAsset async loading is thread-safe.
    private struct Source: @unchecked Sendable {
        let asset: AVAsset
        let audioMix: AVAudioMix?
        let generation: Int
    }

    private struct Request: Sendable {
        let sample: Int64
        let direction: Direction
    }

    private struct PCMWindow: Sendable {
        let startSample: Int64
        let left: [Int16]
        let right: [Int16]
        let hasAudioTracks: Bool

        var endSample: Int64 { startSample + Int64(left.count) }
    }

    private struct CachedWindow {
        let window: PCMWindow
        var lastUsed: UInt64
        let inserted: UInt64
    }

    nonisolated private static let sampleRate = 48_000.0
    nonisolated private static let sampleTimescale: CMTimeScale = 48_000
    nonisolated private static let channelCount: AVAudioChannelCount = 2
    nonisolated private static let cacheFrameCount = 96_000
    nonisolated private static let grainFrameCount = 2_400
    nonisolated private static let fadeFrameCount = 144
    nonisolated private static let meterFrameCount = 960
    nonisolated private static let meterPrefetchFrameCount = 12_000
    nonisolated private static let prefetchMarginFrameCount = 24_000
    nonisolated private static let maxCachedWindows = 256
    nonisolated private static let mixInvalidationDebounce = Duration.milliseconds(250)
    nonisolated private static let failedDecodeRetryDelay = Duration.seconds(1)

    // All AVAssetReader operations stay serialized off the cooperative pool.
    nonisolated private static let scrubDecodeQueue = DispatchQueue(
        label: "io.palmier.pro.scrub-decode",
        qos: .userInitiated
    )

    private final class ReaderSession: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderAudioMixOutput
        private var didFinish = false

        init(reader: AVAssetReader, output: AVAssetReaderAudioMixOutput) {
            self.reader = reader
            self.output = output
        }

        func finishOnDecodeQueue() {
            guard !didFinish else { return }
            didFinish = true
            reader.cancelReading()
        }

        var canReadOnDecodeQueue: Bool { !didFinish }
    }

    // Mutable reader ownership is accessed only on scrubDecodeQueue.
    private final class ReaderQueueState: @unchecked Sendable {
        var activeSession: ReaderSession?
    }

    nonisolated private static let readerQueueState = ReaderQueueState()

    private struct ReaderResult: @unchecked Sendable {
        let buffer: CMSampleBuffer?
        let status: AVAssetReader.Status
    }

    // Loaded tracks are immutable and consumed only on scrubDecodeQueue.
    private struct ReaderConfiguration: @unchecked Sendable {
        let source: Source
        let tracks: [AVAssetTrack]
        let startSample: Int64
        let frameCount: Int64
    }

    nonisolated private static func finishReading(_ session: ReaderSession) {
        scrubDecodeQueue.async {
            session.finishOnDecodeQueue()
            if readerQueueState.activeSession === session {
                readerQueueState.activeSession = nil
            }
        }
    }

    nonisolated private static func nextSampleBuffer(from session: ReaderSession) async -> ReaderResult {
        return await withCheckedContinuation { continuation in
            scrubDecodeQueue.async {
                guard readerQueueState.activeSession === session,
                      session.canReadOnDecodeQueue else {
                    continuation.resume(returning: ReaderResult(buffer: nil, status: .cancelled))
                    return
                }
                let buffer = session.output.copyNextSampleBuffer()
                continuation.resume(returning: ReaderResult(
                    buffer: buffer,
                    status: buffer == nil ? session.reader.status : .reading
                ))
            }
        }
    }

    private let meter: AudioMeterHub
    private let output = ScrubAudioOutput(sampleRate: sampleRate)

    private var source: Source?
    private var sourceGeneration = 0
    private var windows: [CachedWindow] = []
    private var useCounter: UInt64 = 0
    private var latestRequest: Request?
    private var latestMeterSample: Int64?
    private var lastRequestedSample: Int64?
    private var lastDirection: Direction = .forward
    private var decodeTask: Task<Void, Never>?
    private var pendingDecodeRange: Range<Int64>?
    private var lastFailedDecode: FailedDecode?
    private var mixInvalidationTask: Task<Void, Never>?
    private var lifecycleObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private struct FailedDecode {
        let range: Range<Int64>
        let generation: Int
        let at: ContinuousClock.Instant
    }

    init(meter: AudioMeterHub) {
        self.meter = meter
        observeLifecycle()
    }

    isolated deinit {
        teardown()
    }

    func configure(asset: AVAsset?, audioMix: AVAudioMix?, resetMeter: Bool = true) {
        let mixOnlyChange = asset != nil && asset === source?.asset
        resetScrubState(cancelDecode: true)
        output.stop()
        sourceGeneration &+= 1
        source = asset.map { Source(asset: $0, audioMix: audioMix, generation: sourceGeneration) }
        if mixOnlyChange {
            scheduleMixInvalidation()
        } else {
            mixInvalidationTask?.cancel()
            mixInvalidationTask = nil
            windows.removeAll()
        }
        if resetMeter { meter.reset() }
    }

    private func scheduleMixInvalidation() {
        mixInvalidationTask?.cancel()
        mixInvalidationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mixInvalidationDebounce)
            guard !Task.isCancelled, let self else { return }
            self.mixInvalidationTask = nil
            self.windows.removeAll()
        }
    }

    func scrub(to time: CMTime, movingForward: Bool? = nil) {
        guard let source, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let sample = Int64((seconds * Self.sampleRate).rounded())
        guard sample != lastRequestedSample else { return }
        let direction: Direction
        if let movingForward {
            direction = movingForward ? .forward : .reverse
            lastDirection = direction
        } else if let previous = lastRequestedSample {
            direction = sample > previous ? .forward : .reverse
            lastDirection = direction
        } else {
            direction = lastDirection
        }
        lastRequestedSample = sample
        latestMeterSample = nil

        let request = Request(sample: sample, direction: direction)
        latestRequest = request
        if let window = serveableWindow(for: sample) {
            play(request: request, from: window)
            prefetchIfNeeded(sample: sample, direction: direction, from: window, source: source)
        } else {
            requestWindow(around: sample, direction: direction, source: source)
        }
    }

    func meterPlayback(at time: CMTime) {
        guard let source, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let sample = Int64((seconds * Self.sampleRate).rounded())
        latestMeterSample = sample
        if let window = meterableWindow(for: sample) {
            publishMeter(sample: sample, from: window)
            if sample + Int64(Self.meterPrefetchFrameCount) >= window.endSample {
                requestWindow(around: sample, direction: .forward, source: source)
            }
        } else {
            requestWindow(around: sample, direction: .forward, source: source)
        }
    }

    func stopPlaybackMetering() {
        latestMeterSample = nil
        meter.reset()
    }

    func stopScrubbing() {
        resetScrubState(cancelDecode: false)
        output.stop()
    }

    private func resetScrubState(cancelDecode: Bool) {
        if cancelDecode {
            decodeTask?.cancel()
            decodeTask = nil
            pendingDecodeRange = nil
        }
        latestRequest = nil
        latestMeterSample = nil
        lastRequestedSample = nil
        lastDirection = .forward
    }

    func teardown() {
        resetScrubState(cancelDecode: true)
        mixInvalidationTask?.cancel()
        mixInvalidationTask = nil
        source = nil
        windows.removeAll()
        output.invalidate()
        removeLifecycleObservers()
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            observer.center.removeObserver(observer.token)
        }
        lifecycleObservers.removeAll()
    }

    private func requestWindow(around sample: Int64, direction: Direction, source: Source) {
        if let pendingDecodeRange, canServe(sample: sample, from: pendingDecodeRange) { return }
        // Persistently failing media (offline volume, corrupt file) must not spawn a reader per meter tick.
        if let failure = lastFailedDecode,
           failure.generation == source.generation,
           failure.range.contains(sample),
           ContinuousClock.now - failure.at < Self.failedDecodeRetryDelay {
            return
        }

        // Keep one reader in flight; completion resolves the latest scrub or meter request.
        guard decodeTask == nil else { return }
        let startSample = windowStart(around: sample, direction: direction)
        let range = startSample..<(startSample + Int64(Self.cacheFrameCount))
        pendingDecodeRange = range

        decodeTask = Task { [weak self] in
            let window = await Self.decodeWindow(
                source: source,
                startSample: startSample,
                frameCount: Self.cacheFrameCount
            )
            guard !Task.isCancelled, let self else { return }
            self.decodeTask = nil
            self.pendingDecodeRange = nil
            guard source.generation == self.source?.generation else { return }
            guard let window else {
                self.lastFailedDecode = FailedDecode(range: range, generation: source.generation, at: .now)
                if self.latestRequest != nil { self.lastRequestedSample = nil }
                return
            }
            self.lastFailedDecode = nil
            self.insert(window)

            if let request = self.latestRequest {
                if self.canServe(sample: request.sample, from: window) {
                    self.play(request: request, from: window)
                } else {
                    self.requestWindow(around: request.sample, direction: request.direction, source: source)
                }
                return
            }
            if let meterSample = self.latestMeterSample {
                if self.canMeter(sample: meterSample, from: window) {
                    self.publishMeter(sample: meterSample, from: window)
                } else {
                    self.requestWindow(around: meterSample, direction: .forward, source: source)
                }
            }
        }
    }

    /// Bias the decode window in the scrub direction so most of it lands ahead of the playhead.
    private func windowStart(around sample: Int64, direction: Direction) -> Int64 {
        let behind = Int64(Self.cacheFrameCount / 8)
        let offset: Int64 = direction == .forward ? behind : Int64(Self.cacheFrameCount) - behind
        return max(0, sample - offset)
    }

    private func prefetchIfNeeded(sample: Int64, direction: Direction, from window: PCMWindow, source: Source) {
        guard decodeTask == nil else { return }
        let margin = Int64(Self.prefetchMarginFrameCount)
        let nearEdge = direction == .forward
            ? sample + margin >= window.endSample
            : sample - margin <= window.startSample
        guard nearEdge else { return }
        let step = Int64(Self.cacheFrameCount - Self.prefetchMarginFrameCount)
        let next = direction == .forward ? sample + step : sample - step
        guard next >= 0, serveableWindow(for: next, touch: false) == nil else { return }
        requestWindow(around: next, direction: direction, source: source)
    }

    private func serveableWindow(for sample: Int64, touch: Bool = true) -> PCMWindow? {
        cachedWindow(where: { canServe(sample: sample, from: $0) }, touch: touch)
    }

    private func meterableWindow(for sample: Int64) -> PCMWindow? {
        cachedWindow(where: { canMeter(sample: sample, from: $0) }, touch: true)
    }

    // Prefer the most recently inserted covering window so a fresh mix supersedes stale decodes.
    private func cachedWindow(where covers: (PCMWindow) -> Bool, touch: Bool) -> PCMWindow? {
        guard let index = windows.indices
            .filter({ covers(windows[$0].window) })
            .max(by: { windows[$0].inserted < windows[$1].inserted })
        else { return nil }
        if touch {
            useCounter &+= 1
            windows[index].lastUsed = useCounter
        }
        return windows[index].window
    }

    private func insert(_ window: PCMWindow) {
        useCounter &+= 1
        if let index = windows.firstIndex(where: { $0.window.startSample == window.startSample }) {
            windows[index] = CachedWindow(window: window, lastUsed: useCounter, inserted: useCounter)
        } else {
            windows.append(CachedWindow(window: window, lastUsed: useCounter, inserted: useCounter))
        }
        if windows.count > Self.maxCachedWindows,
           let evict = windows.indices.min(by: { windows[$0].lastUsed < windows[$1].lastUsed }) {
            windows.remove(at: evict)
        }
    }

    private func play(request: Request, from window: PCMWindow) {
        latestRequest = nil
        guard window.hasAudioTracks else {
            meter.ingest(.silence)
            output.stop()
            return
        }

        let grain = makeGrain(request: request, from: window)
        meter.ingest(AudioLevelAnalyzer.analyze(
            left: grain.left,
            right: grain.right,
            range: grain.left.indices
        ))
        output.play(grain)
    }

    private func canServe(sample: Int64, from window: PCMWindow) -> Bool {
        canServe(sample: sample, from: window.startSample..<window.endSample)
    }

    private func canServe(sample: Int64, from range: Range<Int64>) -> Bool {
        let halfGrain = Int64(Self.grainFrameCount / 2)
        let hasLeftContext = range.lowerBound == 0 || sample - halfGrain >= range.lowerBound
        return range.contains(sample) && hasLeftContext && sample + halfGrain < range.upperBound
    }

    private func canMeter(sample: Int64, from window: PCMWindow) -> Bool {
        sample >= window.startSample
            && sample + Int64(Self.meterFrameCount) <= window.endSample
    }

    private func publishMeter(sample: Int64, from window: PCMWindow) {
        let start = Int(sample - window.startSample)
        let range = start..<(start + Self.meterFrameCount)
        let analysis = window.hasAudioTracks
            ? AudioLevelAnalyzer.analyzeInt16(left: window.left, right: window.right, range: range)
            : .silence
        meter.ingest(analysis)
    }

    private func makeGrain(request: Request, from window: PCMWindow) -> ScrubAudioGrain {
        let frameCount = Self.grainFrameCount
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)

        let halfGrain = Int64(frameCount / 2)
        for outputIndex in 0..<frameCount {
            let sourceSample: Int64 = switch request.direction {
            case .forward:
                request.sample - halfGrain + Int64(outputIndex)
            case .reverse:
                request.sample + halfGrain - 1 - Int64(outputIndex)
            }
            let cacheIndex = Int(sourceSample - window.startSample)
            let gain = Self.edgeGain(at: outputIndex, frameCount: frameCount)
            if window.left.indices.contains(cacheIndex) {
                left[outputIndex] = Float(window.left[cacheIndex]) * Self.int16ToFloat * gain
                right[outputIndex] = Float(window.right[cacheIndex]) * Self.int16ToFloat * gain
            }
        }
        return ScrubAudioGrain(left: left, right: right)
    }

    nonisolated private static let int16ToFloat: Float = 1.0 / 32767.0  // matches quantize scale so full-scale = 1.0

    nonisolated private static func quantize(_ sample: Float) -> Int16 {
        Int16((max(-1, min(1, sample)) * 32767).rounded())
    }

    private func observeLifecycle() {
        let appCenter = NotificationCenter.default
        let resignObserver = appCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutput()
            }
        }
        lifecycleObservers.append((appCenter, resignObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutput()
            }
        }
        lifecycleObservers.append((workspaceCenter, sleepObserver))
    }

    private func suspendOutput() {
        resetScrubState(cancelDecode: true)
        output.invalidate()
    }

    private static func edgeGain(at index: Int, frameCount: Int) -> Float {
        let fadeIn = min(1, Float(index + 1) / Float(fadeFrameCount))
        let fadeOut = min(1, Float(frameCount - index) / Float(fadeFrameCount))
        return min(fadeIn, fadeOut)
    }

    nonisolated private static func makeReader(
        source: Source,
        tracks: [AVAssetTrack],
        startSample: Int64,
        frameCount: Int64
    ) async -> ReaderSession? {
        let configuration = ReaderConfiguration(
            source: source,
            tracks: tracks,
            startSample: startSample,
            frameCount: frameCount
        )
        return await withCheckedContinuation { continuation in
            scrubDecodeQueue.async {
                continuation.resume(returning: makeReaderOnDecodeQueue(
                    source: configuration.source,
                    tracks: configuration.tracks,
                    startSample: configuration.startSample,
                    frameCount: configuration.frameCount
                ))
            }
        }
    }

    nonisolated private static func makeReaderOnDecodeQueue(
        source: Source,
        tracks: [AVAssetTrack],
        startSample: Int64,
        frameCount: Int64
    ) -> ReaderSession? {
        if let activeSession = readerQueueState.activeSession {
            activeSession.finishOnDecodeQueue()
            readerQueueState.activeSession = nil
        }
        guard let reader = try? AVAssetReader(asset: source.asset) else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.audioMix = source.audioMix
        output.alwaysCopiesSampleData = false
        let session = ReaderSession(reader: reader, output: output)
        guard reader.canAdd(output) else {
            session.finishOnDecodeQueue()
            return nil
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: startSample, timescale: sampleTimescale),
            duration: CMTime(value: frameCount, timescale: sampleTimescale)
        )
        guard reader.startReading() else {
            session.finishOnDecodeQueue()
            return nil
        }
        readerQueueState.activeSession = session
        return session
    }

    @concurrent
    private static func decodeWindow(
        source: Source,
        startSample: Int64,
        frameCount: Int
    ) async -> PCMWindow? {
        guard let tracks = try? await source.asset.loadTracks(withMediaType: .audio) else { return nil }

        guard !tracks.isEmpty else {
            let silence = [Int16](repeating: 0, count: frameCount)
            return PCMWindow(startSample: startSample, left: silence, right: silence, hasAudioTracks: false)
        }

        guard !Task.isCancelled, let session = await makeReader(
            source: source, tracks: tracks, startSample: startSample, frameCount: Int64(frameCount)
        ) else { return nil }
        defer { finishReading(session) }

        return await withTaskCancellationHandler {
            await decodeSamples(session: session, startSample: startSample, frameCount: frameCount)
        } onCancel: {
            finishReading(session)
        }
    }

    nonisolated private static func decodeSamples(
        session: ReaderSession,
        startSample: Int64,
        frameCount: Int
    ) async -> PCMWindow? {
        var leftSamples = [Int16](repeating: 0, count: frameCount)
        var rightSamples = [Int16](repeating: 0, count: frameCount)

        var runningOffset = 0
        var terminalStatus: AVAssetReader.Status = .unknown
        while !Task.isCancelled {
            let result = await nextSampleBuffer(from: session)
            guard !Task.isCancelled else { return nil }
            guard let sampleBuffer = result.buffer else {
                terminalStatus = result.status
                break
            }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let sampleFormat = AVAudioFormat(streamDescription: streamDescription)
            else { continue }

            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0,
                  let pcm = AVAudioPCMBuffer(
                    pcmFormat: sampleFormat,
                    frameCapacity: AVAudioFrameCount(sampleCount)
                  )
            else { continue }
            pcm.frameLength = AVAudioFrameCount(sampleCount)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(sampleCount),
                into: pcm.mutableAudioBufferList
            ) == noErr, let channels = pcm.floatChannelData else { continue }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let destinationOffset: Int
            if presentationTime.isValid {
                let delta = presentationTime - CMTime(value: startSample, timescale: sampleTimescale)
                destinationOffset = Int((delta.seconds * sampleRate).rounded())
            } else {
                destinationOffset = runningOffset
            }

            let sourceChannelCount = Int(sampleFormat.channelCount)
            let rightChannel = channels[min(1, sourceChannelCount - 1)]
            for sourceIndex in 0..<sampleCount {
                let destinationIndex = destinationOffset + sourceIndex
                guard leftSamples.indices.contains(destinationIndex) else { continue }
                leftSamples[destinationIndex] = quantize(channels[0][sourceIndex])
                rightSamples[destinationIndex] = quantize(rightChannel[sourceIndex])
            }
            runningOffset = max(runningOffset, destinationOffset + sampleCount)
        }

        guard !Task.isCancelled, terminalStatus == .completed else { return nil }
        return PCMWindow(startSample: startSample, left: leftSamples, right: rightSamples, hasAudioTracks: true)
    }
}
