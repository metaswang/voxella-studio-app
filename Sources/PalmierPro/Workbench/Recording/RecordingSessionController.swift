import AppKit
import AVFoundation
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit

@Observable
@MainActor
final class RecordingSessionController {
    static let shared = RecordingSessionController()

    var configuration = RecordingCaptureConfiguration()
    var devices: [RecordingAudioDevice] = []
    var phase: RecordingPhase = .idle
    var elapsed: TimeInterval = 0
    var isMicrophoneMuted = false
    var errorMessage: String?
    var lastDiagnostics: RecordingSessionDiagnostics?
    var liveAudioWarning: String?
    var permissionSettingsURL: URL?
    @ObservationIgnored let liveWaveform = RecordingLiveWaveformStore()

    var isPaused: Bool { phase == .paused }
    var canStart: Bool { !phase.isActive && configuration.hasAudioSource }

    private let engine = ScreenCaptureRecordingEngine()
    private let hider = RecordingAppHider()
    private let statusItem = RecordingStatusItemController()
    private var sessionID = UUID()
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pauseAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var didHideApp = false
    private var failedPermission: RecordingPermissionKind?

    private init() {
        statusItem.attach(self)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.discard()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
            }
        }
    }

    func refreshDevices() {
        Task { [weak self] in
            let devices = await RecordingAudioDeviceEnumerator.devices()
            let defaultDeviceID = RecordingAudioDeviceEnumerator.defaultInputUID()
            guard let self else { return }
            self.devices = devices
            self.configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
                self.configuration.microphone,
                devices: devices,
                defaultDeviceID: defaultDeviceID
            )
        }
    }

    func setCaptureMode(_ mode: RecordingCaptureMode) {
        configuration.applyMode(mode)
        configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
            configuration.microphone,
            devices: devices,
            defaultDeviceID: RecordingAudioDeviceEnumerator.defaultInputUID()
        )
    }

    func start(mode: RecordingCaptureMode) {
        guard phase == .idle else { return }
        setCaptureMode(mode)
        start()
    }

    func showRecordingSetup() {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        WorkbenchStore.shared.showRecordImport()
    }

    func start() {
        guard canStart else {
            if !configuration.hasAudioSource {
                errorMessage = RecordingError.audioSourceRequired.localizedDescription
            }
            return
        }
        errorMessage = nil
        permissionSettingsURL = nil
        failedPermission = nil
        configuration.normalizeAudioSources()
        configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
            configuration.microphone,
            devices: devices,
            defaultDeviceID: RecordingAudioDeviceEnumerator.defaultInputUID()
        )
        let id = UUID()
        sessionID = id
        phase = .preparing
        statusItem.update()
        elapsed = 0
        isMicrophoneMuted = false
        lastDiagnostics = nil
        liveAudioWarning = nil
        liveWaveform.reset()
        pauseAccumulated = 0
        pauseStartedAt = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePermissions()
                try Task.checkCancellation()
                guard self.sessionID == id, self.phase == .preparing || self.phase == .picking else { return }

                let picked = try await self.pickCaptureSource()
                try Task.checkCancellation()
                guard self.sessionID == id else { return }

                let outputURL = try await self.makeOutputURL()
                let request = RecordingEngineRequest(
                    configuration: self.configuration,
                    contentFilter: picked.filter,
                    sourceRect: picked.sourceRect,
                    outputURL: outputURL,
                    liveWaveform: self.liveWaveform,
                    onAudioLevelWarning: { [weak self] warning in
                        Task { @MainActor [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.liveAudioWarning = warning.message
                        }
                    }
                )
                try await self.engine.start(request)
                guard self.sessionID == id, self.phase == .preparing else {
                    await self.engine.cancel()
                    return
                }

                if self.configuration.capturesVideo {
                    self.hider.hideWorkbenchWindows()
                    self.didHideApp = true
                }
                self.startedAt = Date()
                self.phase = .recording
                self.startTimer()
                self.statusItem.update()
            } catch is CancellationError {
                guard self.sessionID == id else { return }
                self.resetToIdle()
            } catch let error as RecordingError where error == .cancelled {
                guard self.sessionID == id else { return }
                self.resetToIdle()
            } catch {
                guard self.sessionID == id else { return }
                let recordingError = error as? RecordingError
                self.failedPermission = recordingError?.permissionKind
                self.permissionSettingsURL = recordingError?.permissionKind?.settingsURL
                Log.recording.error(
                    "recording start failed error=\(Log.detail(error)) mode=\(self.configuration.mode.rawValue) microphone=\(String(describing: self.configuration.microphone)) systemAudio=\(self.configuration.capturesSystemAudio)",
                    telemetry: "Recording start failed"
                )
                self.errorMessage = error.localizedDescription
                self.resetToIdle()
            }
        }
    }

    func stop() {
        finish(discard: false)
    }

    func discard() {
        finish(discard: true)
    }

    func togglePause() {
        guard phase.isCapturing else { return }
        if phase == .paused {
            engine.resume()
            liveWaveform.resume(at: ProcessInfo.processInfo.systemUptime)
            if let pauseStartedAt {
                pauseAccumulated += Date().timeIntervalSince(pauseStartedAt)
            }
            pauseStartedAt = nil
            phase = .recording
        } else {
            engine.pause()
            liveWaveform.pause()
            pauseStartedAt = Date()
            phase = .paused
        }
        statusItem.update()
    }

    func toggleMicrophoneMuted() {
        guard configuration.microphone.isEnabled, phase.isCapturing else { return }
        isMicrophoneMuted.toggle()
        engine.setMicrophoneMuted(isMicrophoneMuted)
        statusItem.update()
    }

    private func finish(discard: Bool) {
        guard phase.isCapturing || phase == .preparing || phase == .picking else { return }
        let wasPicking = phase == .picking
        let id = sessionID
        phase = .finishing
        statusItem.update()
        stopTimer()
        if wasPicking {
            DisplayRegionOverlayController.shared.cancelSelection()
            RecordingContentPicker.shared.cancelPending()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                if discard {
                    await self.engine.cancel()
                    self.restoreApp()
                    guard self.sessionID == id else { return }
                    self.resetToIdle()
                    return
                }
                let stopResult = try await self.engine.stop()
                self.restoreApp()
                guard self.sessionID == id else {
                    let leftover = stopResult.url
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: leftover)
                    }
                    return
                }
                self.lastDiagnostics = stopResult.diagnostics
                self.liveAudioWarning = nil
                if stopResult.diagnostics.warningMessage != nil {
                    Log.recording.warning(
                        "recording completed with low audio level microphone=\(String(describing: stopResult.diagnostics.microphone)) systemAudio=\(String(describing: stopResult.diagnostics.systemAudio))"
                    )
                }
                WorkbenchStore.shared.stageRecordedMedia(stopResult.url)
                self.resetToIdle()
            } catch let error as RecordingError where error == .cancelled {
                self.restoreApp()
                guard self.sessionID == id else { return }
                self.resetToIdle()
            } catch {
                self.restoreApp()
                guard self.sessionID == id else { return }
                Log.recording.error(
                    "recording finish failed error=\(Log.detail(error))",
                    telemetry: "Recording finish failed"
                )
                self.errorMessage = error.localizedDescription
                self.resetToIdle()
            }
        }
    }

    func refreshPermissionState() {
        guard failedPermission != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let kind = self.failedPermission
            guard let kind else { return }
            let isAuthorized: Bool
            switch kind {
            case .microphone:
                isAuthorized = RecordingPermission.microphoneStatus() == .authorized
            case .screenCapture:
                if RecordingPermission.tccAllowsScreenCapture() {
                    isAuthorized = true
                } else {
                    isAuthorized = await RecordingPermission.canAccessShareableContent()
                }
            }
            guard isAuthorized, self.failedPermission == kind else { return }
            self.failedPermission = nil
            permissionSettingsURL = nil
            errorMessage = nil
            Log.recording.notice("recording permission became authorized after returning to the app")
        }
    }

    func openPermissionSettings() {
        guard let permissionSettingsURL else { return }
        guard NSWorkspace.shared.open(permissionSettingsURL) else {
            Log.recording.warning("could not open permission settings url=\(permissionSettingsURL.absoluteString)")
            return
        }
    }

    private func preparePermissions() async throws {
        if configuration.microphone.isEnabled {
            try await RecordingPermission.requestMicrophone()
        }
        if configuration.requiresScreenCapturePermissionRequest {
            try await RecordingPermission.requestScreenCapture()
        }
    }

    private struct PickedSource {
        var filter: SCContentFilter?
        var sourceRect: CGRect?
    }

    private func pickCaptureSource() async throws -> PickedSource {
        switch configuration.mode {
        case .audioOnly:
            guard configuration.capturesSystemAudio else {
                return PickedSource(filter: nil, sourceRect: nil)
            }
            return PickedSource(filter: try await displayFilterOrPick(), sourceRect: nil)
        case .display:
            phase = .picking
            statusItem.update()
            let filter = try await RecordingContentPicker.shared.pick(style: .display)
            phase = .preparing
            statusItem.update()
            return PickedSource(filter: filter, sourceRect: nil)
        case .window:
            phase = .picking
            statusItem.update()
            let filter = try await RecordingContentPicker.shared.pick(style: .window)
            phase = .preparing
            statusItem.update()
            return PickedSource(filter: filter, sourceRect: nil)
        case .region:
            phase = .picking
            statusItem.update()
            let filter = try await RecordingContentPicker.shared.pick(style: .display)
            let displayIDs = Set(filter.includedDisplays.map(\.displayID))
            let selection = try await DisplayRegionOverlayController.shared.selectRegion(displayIDs: displayIDs)
            phase = .preparing
            statusItem.update()
            return PickedSource(filter: filter, sourceRect: selection.sourceRect)
        }
    }

    private func displayFilterOrPick(displayID: CGDirectDisplayID? = nil) async throws -> SCContentFilter {
        do {
            return try await displayFilter(displayID: displayID)
        } catch {
            Log.recording.notice(
                "display enumeration failed error=\(Log.detail(error)); falling back to system picker"
            )
            phase = .picking
            statusItem.update()
            let filter = try await RecordingContentPicker.shared.pick(style: .display)
            phase = .preparing
            statusItem.update()
            return filter
        }
    }

    private func displayFilter(displayID: CGDirectDisplayID? = nil) async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await RecordingPermission.shareableContent()
        } catch {
            Log.recording.error(
                "screen capture content enumeration failed error=\(Log.detail(error))",
                telemetry: "Screen capture content enumeration failed"
            )
            if RecordingPermission.isScreenCapturePermissionDenied(error),
               !RecordingPermission.tccAllowsScreenCapture() {
                throw RecordingError.screenCaptureDenied
            }
            if RecordingPermission.tccAllowsScreenCapture() {
                throw RecordingError.screenCaptureNeedsRelaunch
            }
            throw RecordingError.screenCaptureDenied
        }
        let display: SCDisplay
        if let displayID {
            guard let match = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.noDisplay
            }
            display = match
        } else {
            guard let first = content.displays.first else { throw RecordingError.noDisplay }
            display = first
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    private func makeOutputURL() async throws -> URL {
        let directory = WorkbenchStore.recordingMediaDirectory
        let capturesVideo = configuration.capturesVideo
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let ext = capturesVideo ? "mp4" : "m4a"
            return directory.appendingPathComponent("Recording-\(formatter.string(from: Date())).\(ext)")
        }.value
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase.isCapturing else { return }
                self.elapsed = self.currentElapsed()
                self.statusItem.update()
            }
        }
    }

    private func currentElapsed() -> TimeInterval {
        guard let startedAt else { return elapsed }
        var running = Date().timeIntervalSince(startedAt) - pauseAccumulated
        if let pauseStartedAt, phase == .paused {
            running -= Date().timeIntervalSince(pauseStartedAt)
        }
        return max(0, running)
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func restoreApp() {
        if didHideApp {
            hider.restore()
            didHideApp = false
        }
    }

    private func resetToIdle() {
        stopTimer()
        restoreApp()
        phase = .idle
        elapsed = 0
        startedAt = nil
        pauseAccumulated = 0
        pauseStartedAt = nil
        isMicrophoneMuted = false
        liveWaveform.reset()
        statusItem.update()
    }
}
