import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreImage
import CoreVideo
import SwiftUI

enum RecordingMobilePreset: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var preset: AVCaptureSession.Preset { switch self { case .low: .low; case .medium: .medium; case .high: .high } }
}

struct RecordingMobileDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var presets: [RecordingMobilePreset] = RecordingMobilePreset.allCases
}

enum RecordingMobileDevices {
    // Opt in before creating the discovery session, as QuickRecorder does at launch.
    // iOS screen sources can appear after USB trust completes.
    private static let screenCaptureAccess: Void = {
        var enabled: UInt32 = 1
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                               mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                               mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: enabled)), &enabled)
        Log.recording.notice("iOS screen capture opt-in status=\(status)")
        if status != noErr { Log.recording.error("could not enable iOS screen capture devices status=\(status)") }
    }()

    static func enableScreenCaptureDevices() { _ = screenCaptureAccess }

    static func captureDevices() -> [AVCaptureDevice] {
        enableScreenCaptureDevices()
        // Recent macOS releases can classify the iOS bridge with camera types.
        // Restrict media to muxed so ordinary webcams never become screen sources.
        // The muxed screen source identifies iOS devices. Transport metadata is not
        // a reliable USB filter for the CoreMediaIO screen-capture bridge.
        // Resolve a fresh snapshot for each capture, as QuickRecorder does, so a
        // USB reconnect cannot reuse the previous device's native capture handle.
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                                mediaType: .muxed, position: .unspecified).devices
    }

    static func logDiscoveryDiagnostics() {
        let candidates = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                                          mediaType: nil, position: .unspecified).devices
        Log.recording.notice("mobile discovery allSources=\(candidates.count) muxedSources=\(captureDevices().count)")
        for device in candidates {
            Log.recording.notice("mobile source type=\(device.deviceType.rawValue) transport=\(device.transportType) muxed=\(device.hasMediaType(.muxed)) video=\(device.hasMediaType(.video)) connected=\(device.isConnected)")
        }
    }
    static func devices() -> [RecordingMobileDevice] {
        captureDevices().map { device in
            RecordingMobileDevice(id: device.uniqueID, name: device.localizedName,
                                  presets: RecordingMobilePreset.allCases.filter { device.supportsSessionPreset($0.preset) })
        }
    }
}

/// Owns capture configuration and blocking native start/stop calls on its own queue.
/// Samples always leave this adapter in host-clock time, including during preview.
final class MobileDeviceCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                       AVCaptureAudioDataOutputSampleBufferDelegate,
                                       @unchecked Sendable {
    let session = AVCaptureSession()
    // Serialize old-source shutdown with a new preview/recording attempt.
    private static let captureQueue = DispatchQueue(label: "com.voxella.recording.mobile.capture")
    private let sampleQueue = DispatchQueue(label: "com.voxella.recording.mobile.samples")
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var didLogFirstVideoSample = false
    private var didLogFirstAudioSample = false
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPreviewTime: TimeInterval = 0
    private let callbacks = NSLock()
    private var sampleHandler: (@Sendable (CMSampleBuffer, Bool, CMTime) -> Void)?
    private var errorHandler: (@Sendable (RecordingError) -> Void)?
    private var previewHandler: (@Sendable (CGImage) -> Void)?
    private var readyHandler: (@Sendable () -> Void)?
    private var firstFrameDeadline: DispatchWorkItem?

    func setPreviewHandler(_ handler: (@Sendable (CGImage) -> Void)?) {
        callbacks.lock()
        previewHandler = handler
        callbacks.unlock()
    }

    func start(deviceID: String, preset: RecordingMobilePreset, capturesAudio: Bool,
               onSample: @escaping @Sendable (CMSampleBuffer, Bool, CMTime) -> Void,
               onError: @escaping @Sendable (RecordingError) -> Void,
               onReady: (@Sendable () -> Void)? = nil) {
        callbacks.lock()
        sampleHandler = onSample
        errorHandler = onError
        readyHandler = onReady
        firstFrameDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.callbacks.lock()
            let handler = self.errorHandler
            self.callbacks.unlock()
            Log.recording.warning("mobile screen unavailable: no usable video frame before startup deadline")
            handler?(.mobileDeviceNotStreaming)
        }
        firstFrameDeadline = deadline
        // Samples and the deadline share a queue, independently of blocking startRunning.
        sampleQueue.asyncAfter(deadline: .now() + RecordingLifecycleTimeout.mobileFirstFrame, execute: deadline)
        callbacks.unlock()
        Self.captureQueue.async { [self] in
            guard !stopped else { report(.mobileDeviceUnavailable); return }
            if !session.inputs.isEmpty { return }
            do {
                guard let device = RecordingMobileDevices.captureDevices().first(where: { $0.uniqueID == deviceID }) else {
                    throw RecordingError.mobileDeviceUnavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard device.supportsSessionPreset(preset.preset) else {
                    throw RecordingError.captureFailed("The selected device does not support this quality preset.")
                }
                guard session.canAddInput(input) else { throw RecordingError.mobileDeviceUnavailable }
                session.addInput(input)
                guard session.canSetSessionPreset(preset.preset) else {
                    throw RecordingError.captureFailed("The selected device does not support this quality preset.")
                }
                session.sessionPreset = preset.preset
                let video = AVCaptureVideoDataOutput()
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: sampleQueue)
                guard session.canAddOutput(video) else { throw RecordingError.mobileDeviceUnavailable }
                session.addOutput(video)
                if capturesAudio {
                    let audio = AVCaptureAudioDataOutput()
                    // The shared audio mixer consumes PCM; muxed iOS sources
                    // may otherwise vend compressed samples in their native format.
                    audio.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                                           AVLinearPCMBitDepthKey: 32,
                                           AVLinearPCMIsFloatKey: true,
                                           AVLinearPCMIsNonInterleaved: false]
                    audio.setSampleBufferDelegate(self, queue: sampleQueue)
                    guard session.canAddOutput(audio) else {
                        throw RecordingError.captureFailed("Device audio is unavailable. Turn device audio off or reconnect your device.")
                    }
                    session.addOutput(audio)
                    guard audio.connection(with: .audio) != nil else {
                        throw RecordingError.captureFailed("Device audio is unavailable. Turn device audio off or reconnect your device.")
                    }
                }
            } catch {
                report(error as? RecordingError ?? .captureFailed(error.localizedDescription))
                return
            }
            guard !stopped else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "Device capture was interrupted."
                self?.report(.captureInterrupted(message))
            })
            observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.report(.captureInterrupted("Device capture was interrupted. Unlock or reconnect your device. The recording so far was saved."))
            })
            observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                self?.report(.captureInterrupted("The USB device disconnected. The recording so far was saved."))
            })
            session.startRunning()
            Log.recording.notice("mobile capture running=\(session.isRunning) audioEnabled=\(session.outputs.compactMap { $0 as? AVCaptureAudioDataOutput }.first?.connection(with: .audio)?.isEnabled ?? false)")
            if !session.isRunning {
                report(.captureFailed("Device capture could not start. Unlock your device and reconnect it via USB."))
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        callbacks.lock()
        sampleHandler = nil
        errorHandler = nil
        previewHandler = nil
        readyHandler = nil
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        callbacks.unlock()
        Self.captureQueue.async { [self] in
            stopped = true
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if session.isRunning { session.stopRunning() }
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
            completion?()
        }
    }

    private func report(_ error: RecordingError) {
        callbacks.lock()
        let handler = errorHandler
        callbacks.unlock()
        handler?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput, !didLogFirstVideoSample {
            didLogFirstVideoSample = true
            Log.recording.notice("mobile first video sample valid=\(CMSampleBufferIsValid(sampleBuffer)) pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) clockAvailable=\(session.synchronizationClock != nil)")
        }
        if output is AVCaptureAudioDataOutput, !didLogFirstAudioSample {
            didLogFirstAudioSample = true
            Log.recording.notice("mobile first audio sample valid=\(CMSampleBufferIsValid(sampleBuffer)) pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) clockAvailable=\(session.synchronizationClock != nil)")
        }
        if output is AVCaptureVideoDataOutput, CMSampleBufferIsValid(sampleBuffer) {
            updatePreview(sampleBuffer)
        }
        guard CMSampleBufferIsValid(sampleBuffer), let clock = session.synchronizationClock else { return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock())
        guard pts.isNumeric else { return }
        callbacks.lock()
        let handler = sampleHandler
        let ready = output is AVCaptureVideoDataOutput ? readyHandler : nil
        if output is AVCaptureVideoDataOutput {
            readyHandler = nil
            firstFrameDeadline?.cancel()
            firstFrameDeadline = nil
        }
        callbacks.unlock()
        ready?()
        handler?(sampleBuffer, output is AVCaptureVideoDataOutput, pts)
    }

    // Render the same data frames as the recorder, as QuickRecorder's preview
    // does. An AVCaptureVideoPreviewLayer adds/removes native session connections
    // on the main thread and can deadlock against background capture shutdown.
    private func updatePreview(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreviewTime >= 1.0 / 30 else { return }
        callbacks.lock()
        let handler = previewHandler
        callbacks.unlock()
        guard let handler, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lastPreviewTime = now
        let image = CIImage(cvPixelBuffer: buffer)
        // Bound preview work to its small window; recording retains full resolution.
        let scale = min(1, 1120 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let rendered = previewContext.createCGImage(scaled, from: scaled.extent) { handler(rendered) }
    }
}

@MainActor
final class MobileDevicePreviewController {
    static let shared = MobileDevicePreviewController()
    private var window: NSWindow?
    private var source: MobileDeviceCaptureSource?

    func show(source: MobileDeviceCaptureSource) {
        if self.source === source, let window {
            window.orderFrontRegardless()
            return
        }
        self.source?.setPreviewHandler(nil)
        self.source = source
        if let window {
            window.contentView = MobileDevicePreviewView(source: source)
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("Mobile Device Preview")
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = MobileDevicePreviewView(source: source)
        window.minSize = NSSize(width: 200, height: 200)
        window.center()
        self.window = window
        window.orderFrontRegardless()
    }
    func close() {
        source?.setPreviewHandler(nil)
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        source = nil
    }
}

private final class MobileDevicePreviewView: NSView {
    private let waitingLabel = NSTextField(wrappingLabelWithString: L10n.string("Waiting for device screen…"))

    init(source: MobileDeviceCaptureSource) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.actions = ["contents": NSNull()]
        waitingLabel.textColor = .white
        waitingLabel.alignment = .center
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waitingLabel)
        NSLayoutConstraint.activate([
            waitingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            waitingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            waitingLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        source.setPreviewHandler { [weak self] image in
            Task { @MainActor [weak self] in
                self?.waitingLabel.isHidden = true
                self?.layer?.contents = image
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
