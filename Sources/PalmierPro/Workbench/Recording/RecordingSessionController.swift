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
    var permissionMessage: String?
    var lastDiagnostics: RecordingSessionDiagnostics?
    var liveAudioWarning: String?
    var permissionSettingsURL: URL?
    @ObservationIgnored let liveWaveform = RecordingLiveWaveformStore()

    var isPaused: Bool { phase == .paused }
    var canStart: Bool { !phase.isActive && configuration.hasAudioSource }

    private let engine = ScreenCaptureRecordingEngine()
    private let hider = RecordingAppHider()
    private let statusItem = RecordingStatusItemController()
    private let floatingControls = RecordingFloatingControlsController()
    private var sessionID = UUID()
    private var timerTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
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
        requestStart()
    }

    func requestStart() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AccountService.shared.prepareNewContentAccess()
                self.start()
            } catch is AppAccessError {
                self.errorMessage = nil
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func showRecordingSetup() {
        if phase.isCapturing {
            floatingControls.present(session: self)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        WorkbenchStore.shared.showRecordImport()
    }

    func start() {
        do {
            try AccountService.shared.requireNewContentAccess()
        } catch is AppAccessError {
            errorMessage = nil
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard canStart else {
            if !configuration.hasAudioSource {
                errorMessage = RecordingError.audioSourceRequired.localizedDescription
            }
            return
        }
        errorMessage = nil
        permissionMessage = nil
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
        updateControls()
        elapsed = 0
        isMicrophoneMuted = false
        lastDiagnostics = nil
        liveAudioWarning = nil
        liveWaveform.reset()
        pauseAccumulated = 0
        pauseStartedAt = nil

        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePermissions()
                try Task.checkCancellation()
                guard self.sessionID == id, self.phase == .preparing || self.phase == .picking else { return }

                let picked = try await self.pickCaptureSource()
                try Task.checkCancellation()
                guard self.sessionID == id else { return }

                let outputURL = try await self.makeOutputURL()
                try Task.checkCancellation()
                guard self.sessionID == id, self.phase == .preparing else { return }
                try AccountService.shared.requireNewContentAccess()
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
                self.updateControls()
            } catch is CancellationError {
                guard self.sessionID == id, self.phase != .finishing else { return }
                self.resetToIdle()
            } catch let error as RecordingError where error == .cancelled {
                guard self.sessionID == id, self.phase != .finishing else { return }
                self.resetToIdle()
            } catch RecordingError.screenCapturePermissionRequired {
                guard self.sessionID == id, self.phase != .finishing else { return }
                self.failedPermission = .screenCapture
                self.permissionSettingsURL = RecordingPermissionKind.screenCapture.settingsURL
                self.permissionMessage = RecordingError.screenCapturePermissionRequired.localizedDescription
                self.resetToIdle()
            } catch {
                guard self.sessionID == id, self.phase != .finishing else { return }
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
        updateControls()
    }

    func toggleMicrophoneMuted() {
        guard configuration.microphone.isEnabled, phase.isCapturing else { return }
        isMicrophoneMuted.toggle()
        engine.setMicrophoneMuted(isMicrophoneMuted)
        updateControls()
    }

    private func finish(discard: Bool) {
        guard phase.isCapturing || phase == .preparing || phase == .picking else { return }
        preparationTask?.cancel()
        let preparation = preparationTask
        let wasPreparing = phase == .preparing || phase == .picking
        let wasPicking = phase == .picking
        let id = sessionID
        phase = .finishing
        updateControls()
        stopTimer()
        if wasPicking {
            DisplayRegionOverlayController.shared.cancelSelection()
            RecordingContentPicker.shared.cancelPending()
        }

        Task { [weak self] in
            guard let self else { return }
            await preparation?.value
            guard self.sessionID == id else { return }
            do {
                if discard || wasPreparing {
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
                isAuthorized = RecordingPermission.tccAllowsScreenCapture()
            }
            guard isAuthorized, self.failedPermission == kind else { return }
            self.failedPermission = nil
            permissionSettingsURL = nil
            errorMessage = nil
            permissionMessage = nil
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
        try Task.checkCancellation()
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
            updateControls()
            let pickedFilter = try await RecordingContentPicker.shared.pick(style: .display)
            try Task.checkCancellation()
            if #available(macOS 15.2, *) {
                guard pickedFilter.includedDisplays.count == 1,
                      let displayID = pickedFilter.includedDisplays.first?.displayID else {
                    throw RecordingError.noDisplay
                }
                phase = .preparing
                updateControls()
                floatingControls.present(session: self, displayID: displayID)
                let filter = try await displayFilter(displayID: displayID)
                try Task.checkCancellation()
                return PickedSource(filter: filter, sourceRect: nil)
            }
            phase = .preparing
            updateControls()
            return PickedSource(filter: pickedFilter, sourceRect: nil)
        case .window:
            phase = .picking
            updateControls()
            let filter = try await RecordingContentPicker.shared.pick(style: .window)
            try Task.checkCancellation()
            phase = .preparing
            updateControls()
            return PickedSource(filter: filter, sourceRect: nil)
        case .region:
            phase = .picking
            updateControls()
            hider.hideWorkbenchWindows()
            didHideApp = true
            let selection = try await DisplayRegionOverlayController.shared.selectRegion()
            try Task.checkCancellation()
            guard phase == .picking else { throw RecordingError.cancelled }
            phase = .preparing
            floatingControls.present(session: self, displayID: selection.displayID)
            let filter = try await displayFilter(displayID: selection.displayID)
            try Task.checkCancellation()
            guard phase == .preparing else { throw RecordingError.cancelled }
            updateControls()
            return PickedSource(filter: filter, sourceRect: selection.sourceRect)
        }
    }

    private func displayFilterOrPick(displayID: CGDirectDisplayID? = nil) async throws -> SCContentFilter {
        do {
            return try await displayFilter(displayID: displayID)
        } catch {
            try Task.checkCancellation()
            Log.recording.notice(
                "display enumeration failed error=\(Log.detail(error)); falling back to system picker"
            )
            phase = .picking
            updateControls()
            let filter = try await RecordingContentPicker.shared.pick(style: .display)
            try Task.checkCancellation()
            phase = .preparing
            updateControls()
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
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !configuration.capturesVideo || !excluded.isEmpty else {
            throw RecordingError.captureFailed("Could not exclude recording controls from capture. Try again.")
        }
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

    private func updateControls() {
        statusItem.update()
        floatingControls.update(session: self)
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase.isCapturing else { return }
                self.elapsed = self.currentElapsed()
                self.updateControls()
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
        preparationTask = nil
        stopTimer()
        restoreApp()
        phase = .idle
        elapsed = 0
        startedAt = nil
        pauseAccumulated = 0
        pauseStartedAt = nil
        isMicrophoneMuted = false
        liveWaveform.reset()
        updateControls()
    }
}
