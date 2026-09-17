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
    private let sleepPreventer = RecordingSleepPreventer()
    private var sessionID = UUID()
    private var timerTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pauseAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var didHideApp = false
    private var failedPermission: RecordingPermissionKind?
    private var captureBackend = "none"
    private var pendingStopReason: RecordingStopReason?
    private var activeConfiguration: RecordingCaptureConfiguration?

    private init() {
        statusItem.attach(self)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayChange()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillSleep()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidWake()
            }
        }
        Task { [weak self] in
            self?.recoverInterruptedSessions()
        }
    }

    func refreshDevices() {
        Task { [weak self] in
            let devices = await RecordingAudioDeviceEnumerator.devices()
            let defaultDeviceID = RecordingAudioDeviceEnumerator.defaultInputUID()
            guard let self else { return }
            self.devices = devices
            guard !self.phase.isActive else { return }
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
        let frozenMicrophone = configuration.microphone
        activeConfiguration = configuration
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
        pendingStopReason = nil

        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = await RecordingAudioDeviceEnumerator.devices()
                let defaultDeviceID = RecordingAudioDeviceEnumerator.defaultInputUID()
                try Task.checkCancellation()
                guard self.sessionID == id, self.phase == .preparing || self.phase == .picking else { return }
                self.devices = devices
                if case .device(let deviceID) = frozenMicrophone {
                    if RecordingAudioDeviceEnumerator.captureDevice(uniqueID: deviceID) == nil {
                        throw RecordingError.microphoneUnavailable
                    }
                    self.configuration.microphone = .device(id: deviceID)
                } else if frozenMicrophone == .systemDefault {
                    self.configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
                        .systemDefault,
                        devices: devices,
                        defaultDeviceID: defaultDeviceID
                    )
                }
                self.activeConfiguration = self.configuration

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
                let configuration = self.activeConfiguration ?? self.configuration
                let request = RecordingEngineRequest(
                    configuration: configuration,
                    contentFilter: picked.filter,
                    sourceRect: picked.sourceRect,
                    outputURL: outputURL,
                    sessionID: id,
                    displayID: picked.displayID,
                    liveWaveform: self.liveWaveform,
                    onAudioLevelWarning: { [weak self] warning in
                        Task { @MainActor [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.liveAudioWarning = warning.message
                        }
                    },
                    onRuntimeEvent: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleRuntimeEvent(event, sessionID: id)
                        }
                    }
                )
                self.captureBackend = Self.backendName(for: self.activeConfiguration ?? self.configuration)
                try await self.engine.start(request)
                guard self.sessionID == id, self.phase == .preparing else {
                    await self.engine.cancel(expectedSessionID: id)
                    return
                }

                if self.configuration.capturesVideo {
                    self.hider.hideWorkbenchWindows()
                    self.didHideApp = true
                }
                self.startedAt = Date()
                self.phase = .recording
                self.sleepPreventer.start()
                self.startTimer()
                self.updateControls()
                self.logStop(
                    reason: "started",
                    extra: "display=\(picked.displayID.map(String.init) ?? "none")"
                )
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

    func prepareForTermination() async -> RecordingTerminationOutcome {
        switch phase {
        case .idle:
            return .idle
        case .preparing, .picking:
            pendingStopReason = .termination
            discard()
        case .recording, .paused, .finishing:
            pendingStopReason = .termination
            if phase != .finishing {
                finish(discard: false, mode: .salvage)
            }
        }
        let deadline = Date().addingTimeInterval(RecordingLifecycleTimeout.termination)
        while phase != .idle, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if phase == .idle {
            return engine.hasDurableSalvage ? .salvaged : .idle
        }
        if engine.hasDurableSalvage {
            Log.recording.error(
                "recording termination wait timed out with salvage session=\(sessionID.uuidString)"
            )
            return .salvaged
        }
        Log.recording.error(
            "recording termination wait timed out phase=\(String(describing: phase)) session=\(sessionID.uuidString)"
        )
        return .unsafe("Recording is still saving. Wait a moment and quit again.")
    }

    private func finish(discard: Bool, mode: RecordingFinishMode? = nil) {
        guard phase.isCapturing || phase == .preparing || phase == .picking else { return }
        preparationTask?.cancel()
        let wasPreparing = phase == .preparing || phase == .picking
        let wasPicking = phase == .picking
        let id = sessionID
        let reason = pendingStopReason ?? (discard ? .userDiscard : .userStop)
        pendingStopReason = nil
        logStop(reason: reason.logLabel)
        phase = .finishing
        updateControls()
        stopTimer()
        if wasPicking {
            DisplayRegionOverlayController.shared.cancelSelection()
            RecordingContentPicker.shared.cancelPending()
        }
        let finishMode = mode ?? (discard ? .discard : .export)

        Task { [weak self] in
            guard let self else { return }
            do {
                if discard || wasPreparing {
                    await self.engine.cancel(expectedSessionID: id)
                    self.restoreApp()
                    guard self.sessionID == id else { return }
                    self.resetToIdle()
                    return
                }
                let stopResult = try await self.engine.stop(
                    expectedSessionID: id,
                    mode: finishMode,
                    reason: reason
                )
                self.restoreApp()
                guard self.sessionID == id else { return }
                self.lastDiagnostics = stopResult.diagnostics
                self.liveAudioWarning = stopResult.warnings.first
                if stopResult.diagnostics.warningMessage != nil {
                    Log.recording.warning(
                        "recording completed with low audio level microphone=\(String(describing: stopResult.diagnostics.microphone)) systemAudio=\(String(describing: stopResult.diagnostics.systemAudio))"
                    )
                }
                Log.recording.notice(
                    "recording stop summary reason=\(reason.logLabel) outcome=\(stopResult.outcome.rawValue) session=\(id.uuidString) segments=\(stopResult.segmentURLs.count) journal=\(stopResult.journalPersisted) droppedMic=\(stopResult.diagnostics.microphoneDropped) droppedSystem=\(stopResult.diagnostics.systemAudioDropped) failedAppends=\(stopResult.diagnostics.failedAppends) restarts=\(stopResult.diagnostics.restartCount)"
                )
                let stagedURLs: [URL]
                switch stopResult.outcome {
                case .complete, .partial:
                    stagedURLs = [stopResult.url]
                case .rawSegments, .recoveryRequired:
                    stagedURLs = stopResult.segmentURLs.isEmpty ? [stopResult.url] : stopResult.segmentURLs
                }
                WorkbenchStore.shared.stageRecordedMedia(urls: stagedURLs, sessionID: stopResult.sessionID)
                self.resetToIdle()
            } catch let error as RecordingError where error == .cancelled {
                self.restoreApp()
                guard self.sessionID == id else { return }
                self.resetToIdle()
            } catch {
                self.restoreApp()
                guard self.sessionID == id else { return }
                self.logStop(reason: reason.logLabel, error: error)
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
        var displayID: CGDirectDisplayID?
    }

    private func pickCaptureSource() async throws -> PickedSource {
        switch configuration.mode {
        case .audioOnly:
            guard configuration.capturesSystemAudio else {
                return PickedSource(filter: nil, sourceRect: nil, displayID: nil)
            }
            return try await displayFilterOrPick()
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
                return try await displayFilter(displayID: displayID)
            }
            phase = .preparing
            updateControls()
            return PickedSource(filter: pickedFilter, sourceRect: nil, displayID: nil)
        case .window:
            phase = .picking
            updateControls()
            let filter = try await RecordingContentPicker.shared.pick(style: .window)
            try Task.checkCancellation()
            phase = .preparing
            updateControls()
            return PickedSource(filter: filter, sourceRect: nil, displayID: nil)
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
            var picked = try await displayFilter(displayID: selection.displayID)
            try Task.checkCancellation()
            guard phase == .preparing else { throw RecordingError.cancelled }
            picked.sourceRect = selection.sourceRect
            updateControls()
            return picked
        }
    }

    private func displayFilterOrPick(displayID: CGDirectDisplayID? = nil) async throws -> PickedSource {
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
            return PickedSource(filter: filter, sourceRect: nil, displayID: nil)
        }
    }

    private func displayFilter(displayID: CGDirectDisplayID? = nil) async throws -> PickedSource {
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
        return PickedSource(
            filter: SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: []),
            sourceRect: nil,
            displayID: display.displayID
        )
    }

    private func makeOutputURL() async throws -> URL {
        let directory = WorkbenchStore.recordingMediaDirectory
        let capturesVideo = configuration.capturesVideo
        var audioTracks = 0
        if configuration.capturesSystemAudio { audioTracks += 1 }
        if configuration.microphone.isEnabled { audioTracks += 1 }
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return RecordingSessionManifest.uniqueOutputURL(
                directory: directory,
                capturesVideo: capturesVideo,
                audioTrackCount: audioTracks
            )
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
        sleepPreventer.stop()
        phase = .idle
        elapsed = 0
        startedAt = nil
        pauseAccumulated = 0
        pauseStartedAt = nil
        isMicrophoneMuted = false
        captureBackend = "none"
        activeConfiguration = nil
        pendingStopReason = nil
        liveWaveform.reset()
        updateControls()
    }

    private func handleRuntimeEvent(_ event: RecordingRuntimeEvent, sessionID id: UUID) {
        guard sessionID == id else { return }
        switch event {
        case .recovering(_, let message):
            guard phase.isCapturing else { return }
            liveAudioWarning = message
        case .recovered:
            guard phase.isCapturing else { return }
            liveAudioWarning = nil
        case .failed(let error, let reason):
            guard phase.isCapturing else { return }
            pendingStopReason = stopReason(for: error, fallback: reason)
            logStop(reason: pendingStopReason?.logLabel ?? reason, error: error)
            errorMessage = error.localizedDescription
            finish(discard: false)
        case .userStopped:
            guard phase.isCapturing else { return }
            pendingStopReason = .systemUserStopped
            errorMessage = "Recording was stopped from the system Screen Recording control."
            finish(discard: false)
        case .captureTargetLost(let message):
            guard phase.isCapturing else { return }
            pendingStopReason = .captureTargetLost
            errorMessage = message
            liveAudioWarning = message
        }
    }

    private func stopReason(for error: RecordingError, fallback: String) -> RecordingStopReason {
        switch error {
        case .diskSpaceLow:
            .diskSpace
        case .microphoneUnavailable:
            .microphoneLost
        case .captureTargetUnavailable:
            .captureTargetLost
        case .writerFailed(let message):
            .writerFailed(message)
        case .captureInterrupted:
            fallback.contains("microphone") ? .microphoneLost : .captureInterrupted(fallback)
        default:
            .captureInterrupted(fallback)
        }
    }

    private func handleWillSleep() {
        guard phase.isCapturing else { return }
        logStop(reason: "system will sleep")
    }

    private func handleDidWake() {
        guard phase.isCapturing else { return }
        logStop(reason: "system did wake")
        engine.handleSystemWake()
    }

    private func handleDisplayChange() {
        guard phase.isCapturing, configuration.requiresScreenCapture else { return }
        logStop(reason: "display change")
        engine.handleDisplayChange()
    }

    private func recoverInterruptedSessions() {
        let recovered = RecordingSessionManifest.recoverInterruptedSessions(
            in: WorkbenchStore.recordingMediaDirectory
        )
        guard phase == .idle, let session = recovered.first else { return }
        liveAudioWarning = "A previous recording was recovered after an interruption."
        WorkbenchStore.shared.stageRecordedMedia(urls: session.urls, sessionID: UUID(uuidString: session.sessionID))
    }

    private func logStop(reason: String, error: Error? = nil, extra: String? = nil) {
        let ns = error as NSError?
        var message = "recording stop reason=\(reason) session=\(sessionID.uuidString) mode=\(configuration.mode.rawValue) backend=\(captureBackend) device=\(configuration.microphone.deviceID ?? "default") systemAudio=\(configuration.capturesSystemAudio) elapsed=\(currentElapsed()) error=\(error.map(Log.detail) ?? "none") domain=\(ns?.domain ?? "none") code=\(ns?.code ?? 0)"
        if let extra, !extra.isEmpty {
            message += " \(extra)"
        }
        if error == nil {
            Log.recording.notice(message)
        } else {
            Log.recording.error(message, telemetry: "Recording stop")
        }
    }

    private static func backendName(for configuration: RecordingCaptureConfiguration) -> String {
        if configuration.requiresScreenCapture {
            return "stream"
        }
        if configuration.microphone.deviceID == nil {
            return "engine"
        }
        return "microphone"
    }
}
