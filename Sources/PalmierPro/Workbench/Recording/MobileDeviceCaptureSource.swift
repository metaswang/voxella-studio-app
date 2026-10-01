import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import CoreMediaIO
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
    static func captureDevices() -> [AVCaptureDevice] {
        var enabled: UInt32 = 1
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                               mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                               mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: enabled)), &enabled)
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
            .filter { $0.hasMediaType(.muxed) && $0.transportType == Int32(kAudioDeviceTransportTypeUSB) }
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
                                       AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.voxella.recording.mobile.capture")
    private let sampleQueue = DispatchQueue(label: "com.voxella.recording.mobile.samples")
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private let callbacks = NSLock()
    private var sampleHandler: (@Sendable (CMSampleBuffer, Bool, CMTime) -> Void)?
    private var errorHandler: (@Sendable (RecordingError) -> Void)?

    func start(deviceID: String, preset: RecordingMobilePreset, capturesAudio: Bool,
               onSample: @escaping @Sendable (CMSampleBuffer, Bool, CMTime) -> Void,
               onError: @escaping @Sendable (RecordingError) -> Void) {
        callbacks.lock()
        sampleHandler = onSample
        errorHandler = onError
        callbacks.unlock()
        captureQueue.async { [self] in
            guard session.inputs.isEmpty else { return }
            do {
                guard let device = RecordingMobileDevices.captureDevices().first(where: { $0.uniqueID == deviceID }) else {
                    throw RecordingError.mobileDeviceUnavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canSetSessionPreset(preset.preset) else {
                    throw RecordingError.captureFailed("The selected device does not support this quality preset.")
                }
                session.sessionPreset = preset.preset
                guard session.canAddInput(input) else { throw RecordingError.mobileDeviceUnavailable }
                session.addInput(input)
                let video = AVCaptureVideoDataOutput()
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: sampleQueue)
                guard session.canAddOutput(video) else { throw RecordingError.mobileDeviceUnavailable }
                session.addOutput(video)
                if capturesAudio {
                    let audio = AVCaptureAudioDataOutput()
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
            observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                self?.report(.captureInterrupted("The USB device disconnected. The recording so far was saved."))
            })
            session.startRunning()
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        callbacks.lock()
        sampleHandler = nil
        errorHandler = nil
        callbacks.unlock()
        captureQueue.async { [self] in
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
        guard CMSampleBufferIsValid(sampleBuffer), let clock = session.synchronizationClock else { return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock())
        guard pts.isNumeric else { return }
        callbacks.lock()
        let handler = sampleHandler
        callbacks.unlock()
        handler?(sampleBuffer, output is AVCaptureVideoDataOutput, pts)
    }
}

@MainActor
final class MobileDevicePreviewController {
    static let shared = MobileDevicePreviewController()
    private var window: NSWindow?
    private var source: MobileDeviceCaptureSource?

    func show(source: MobileDeviceCaptureSource) {
        self.source = source
        if let window { window.orderFrontRegardless(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("Mobile Device Preview")
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = MobileDevicePreviewView(session: source.session)
        window.minSize = NSSize(width: 200, height: 200)
        window.center()
        self.window = window
        window.orderFrontRegardless()
    }
    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        source = nil
    }
}

private final class MobileDevicePreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let hint = NSTextField(labelWithString: L10n.string("Unlock your device and trust this Mac"))
        hint.textColor = .white
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: centerXAnchor), hint.centerYAnchor.constraint(equalTo: centerYAnchor)])
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}
