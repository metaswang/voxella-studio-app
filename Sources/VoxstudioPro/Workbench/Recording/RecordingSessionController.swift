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
    var mobileDevices: [RecordingMobileDevice] = []
    private(set) var isDiscoveringMobileDevices = false
    private(set) var mobileCameraAccessDenied = false
    var savedRecordingURL: URL?
    var phase: RecordingPhase = .idle
    private(set) var isRequestingStart = false
    private(set) var startupMessage: String?
    private(set) var isWaitingForMobilePreview = false
    private(set) var canRetryStart = false
    private(set) var activeApplicationSelection: RecordingApplicationSelection?
    var elapsed: TimeInterval = 0
    var isMicrophoneMuted = false
    var errorMessage: String?
    var permissionMessage: String?
    var lastDiagnostics: RecordingSessionDiagnostics?
    var liveAudioWarning: String?
    var permissionSettingsURL: URL?
    @ObservationIgnored let liveWaveform = RecordingLiveWaveformStore()

    var supportedMobilePresets: [RecordingMobilePreset] {
        mobileDevices.first { $0.id == configuration.mobileDeviceID }?.presets ?? RecordingMobilePreset.allCases
    }

    var isPaused: Bool { phase == .paused }
    var canStart: Bool { phase == .idle && !isRequestingStart && !isWaitingForMobilePreview && configuration.hasCaptureSource && (configuration.mode != .mobileDevice || configuration.mobileDeviceID != nil) }

    /// All recording feedback is rendered by the shared floating tip host.
    var feedback: WorkbenchTip? {
        let message: String
        let kind: WorkbenchTipKind
        if let errorMessage { message = errorMessage; kind = canRetryStart ? .warning : .error }
        else if let permissionMessage { message = permissionMessage; kind = .info }
        else if let warning = liveAudioWarning ?? (!phase.isActive ? lastDiagnostics?.warningMessage : nil) {
            message = warning; kind = .warning
        } else if !phase.isActive, savedRecordingURL != nil {
            message = L10n.string("Recording saved."); kind = .success
        } else if !configuration.hasCaptureSource, !phase.isActive {
            message = L10n.string("Select an audio source"); kind = .warning
        } else { return nil }
        let action: WorkbenchTipAction? = permissionSettingsURL != nil ? .openRecordingPermissionSettings
            : savedRecordingURL != nil && !phase.isActive ? .showRecordingInFinder : nil
        let label = action == .openRecordingPermissionSettings ? L10n.string("Open System Settings")
            : action == .showRecordingInFinder ? L10n.string("Show recording in Finder") : nil
        return WorkbenchTip(id: "recording.feedback", message: message, kind: kind,
                            actionLabel: label, action: action, autoDismiss: kind != .error && !canRetryStart)
    }

    private let engine = ScreenCaptureRecordingEngine()
    private let review = RecordingReviewController()
    private var mobilePreviewSource: MobileDeviceCaptureSource?
    private var mobilePreviewConfiguration: RecordingCaptureConfiguration?
    private let hider = RecordingAppHider()
    private let statusItem = RecordingStatusItemController()
    private let floatingControls = RecordingFloatingControlsController()
    private let sleepPreventer = RecordingSleepPreventer()
    private var sessionID = UUID()
    private var timerTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var accessPreparationTask: Task<Void, Never>?
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
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMobileDevices() }
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
            await self?.recoverInterruptedSessions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let exitedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in self?.checkApplicationTargets(excluding: exitedPID) }
        }
    }

    func refreshMobileDevices() {
        guard !isDiscoveringMobileDevices else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        mobileCameraAccessDenied = status == .denied || status == .restricted
        guard status == .authorized else { return }
        isDiscoveringMobileDevices = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { RecordingMobileDevices.devices() }.value
            guard let self else { return }
            self.isDiscoveringMobileDevices = false
            if self.mobileDevices != found { self.mobileDevices = found }
            guard !self.phase.isActive, !self.isRequestingStart else { return }
            if !found.contains(where: { $0.id == self.configuration.mobileDeviceID }) {
                self.configuration.mobileDeviceID = found.first?.id
            }
            self.normalizeMobilePreset()
        }
    }

    /// Scoped to the visible mobile panel; retries cover delayed unlock/trust and
    /// permission changes even when AVFoundation sends no connection notification.
    func monitorMobileDevices() async {
        Log.recording.notice("mobile discovery camera authorization=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            await Task.detached(priority: .utility) { RecordingMobileDevices.logDiscoveryDiagnostics() }.value
        }
        while !Task.isCancelled, configuration.mode == .mobileDevice {
            refreshMobileDevices()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func normalizeMobilePreset() {
        if !supportedMobilePresets.contains(configuration.mobilePreset), let preset = supportedMobilePresets.last {
            configuration.mobilePreset = preset
        }
    }

    func showMobilePreview() { engine.showMobilePreview() }

    func previewMobileDevice() {
        guard phase == .idle, !isRequestingStart, !isWaitingForMobilePreview, let id = configuration.mobileDeviceID else { return }
        let requested = configuration
        errorMessage = nil
        canRetryStart = false
        isRequestingStart = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRequestingStart = false }
            do {
                try await self.preparePermissions()
                await self.closeMobilePreview()
                let source = MobileDeviceCaptureSource()
                self.mobilePreviewSource = source
                self.mobilePreviewConfiguration = requested
                self.isWaitingForMobilePreview = true
                MobileDevicePreviewController.shared.show(source: source)
                source.start(deviceID: id, preset: requested.mobilePreset, capturesAudio: requested.capturesDeviceAudio,
                             onSample: { _, _, _ in }, onError: { [weak self, weak source] error in
                    Task { @MainActor [weak self, weak source] in
                        guard let self, let source, self.mobilePreviewSource === source else { return }
                        self.errorMessage = error.localizedDescription
                        self.canRetryStart = error == .mobileDeviceNotStreaming
                        await self.closeMobilePreview()
                    }
                }, onReady: { [weak self, weak source] in
                    Task { @MainActor [weak self, weak source] in
                        guard let self, let source, self.mobilePreviewSource === source else { return }
                        self.isWaitingForMobilePreview = false
                    }
                })
            } catch {
                self.errorMessage = error.localizedDescription
                self.failedPermission = (error as? RecordingError)?.permissionKind
                self.permissionSettingsURL = self.failedPermission?.settingsURL
            }
        }
    }

    private func closeMobilePreview() async {
        isWaitingForMobilePreview = false
        guard let source = mobilePreviewSource else { return }
        mobilePreviewSource = nil
        mobilePreviewConfiguration = nil
        MobileDevicePreviewController.shared.close()
        _ = try? await RecordingTimeout.withTimeout(seconds: RecordingLifecycleTimeout.streamStop, timeoutError: .cancelled) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                source.stop { continuation.resume() }
            }
        }
    }

    func cancelPreparation() {
        if phase == .preparing || phase == .picking { discard() }
        else if isWaitingForMobilePreview { Task { await closeMobilePreview() } }
    }

    func refreshDevices() {
        refreshMobileDevices()
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
        guard phase == .idle, !isRequestingStart else { return }
        if mode != .mobileDevice { Task { await closeMobilePreview() } }
        configuration.applyMode(mode)
        configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
            configuration.microphone,
            devices: devices,
            defaultDeviceID: RecordingAudioDeviceEnumerator.defaultInputUID()
        )
    }

    func start(mode: RecordingCaptureMode) {
        guard phase == .idle, !isRequestingStart else { return }
        setCaptureMode(mode)
        requestStart()
    }

    func start(_ request: LocalRecordingRequest) {
        guard phase == .idle, !isRequestingStart else { return }
        configuration = request.configuration(from: configuration)
        requestStart(targetBundleIdentifier: request.applicationBundleIdentifier, targetProcessID: request.applicationProcessID)
    }

    func requestStart(targetBundleIdentifier: String? = nil, targetProcessID: Int32? = nil) {
        guard canStart else { return }
        isRequestingStart = true
        let requestedConfiguration = configuration
        accessPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRequestingStart = false
                self.accessPreparationTask = nil
            }
            do {
                try await AccountService.shared.prepareNewContentAccess()
                try Task.checkCancellation()
                guard self.phase == .idle else { return }
                self.configuration = requestedConfiguration
                self.isRequestingStart = false
                self.start(preferredBundleIdentifier: targetBundleIdentifier, preferredProcessID: targetProcessID)
            } catch is CancellationError {
                return
            } catch is AppAccessError {
                self.errorMessage = nil
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func showRecordingSetup() {
        if phase == .reviewing || phase == .trimming { review.show(); return }
        if phase.isCapturing {
            floatingControls.present(session: self)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        WorkbenchStore.shared.showRecordImport()
    }

    private func start(preferredBundleIdentifier: String? = nil, preferredProcessID: Int32? = nil) {
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
            if !configuration.hasCaptureSource {
                errorMessage = RecordingError.audioSourceRequired.localizedDescription
            }
            return
        }
        savedRecordingURL = nil
        errorMessage = nil
        canRetryStart = false
        startupMessage = nil
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

                try await self.preparePermissions(requestAudio: self.configuration.mode != .region)
                try Task.checkCancellation()
                guard self.sessionID == id, self.phase == .preparing || self.phase == .picking else { return }

                let picked = try await self.pickCaptureSource(
                    preferredBundleIdentifier: preferredBundleIdentifier, preferredProcessID: preferredProcessID
                )
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.configuration.microphone = RecordingAudioDeviceEnumerator.resolvedMicrophone(
                    self.configuration.microphone, devices: self.devices,
                    defaultDeviceID: RecordingAudioDeviceEnumerator.defaultInputUID())
                if let deviceID = self.configuration.microphone.deviceID,
                   RecordingAudioDeviceEnumerator.captureDevice(uniqueID: deviceID) == nil {
                    throw RecordingError.microphoneUnavailable
                }
                try await self.preparePermissions()
                try Task.checkCancellation()
                self.configuration.video.save()
                self.activeConfiguration = self.configuration
                self.activeApplicationSelection = picked.applicationSelection

                if let previewConfiguration = self.mobilePreviewConfiguration,
                   (previewConfiguration.mobileDeviceID != self.configuration.mobileDeviceID
                    || previewConfiguration.mobilePreset != self.configuration.mobilePreset
                    || previewConfiguration.capturesDeviceAudio != self.configuration.capturesDeviceAudio) {
                    await self.closeMobilePreview()
                }
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
                    },
                    applicationSelection: picked.applicationSelection,
                    mobilePreviewSource: self.mobilePreviewSource
                )
                self.captureBackend = Self.backendName(for: self.activeConfiguration ?? self.configuration)
                // Ownership moves before starting: a failed engine start also
                // stops this session, so it must never be reused as a preview.
                self.mobilePreviewSource = nil
                self.mobilePreviewConfiguration = nil
                self.startupMessage = L10n.string(configuration.mode == .mobileDevice
                    ? "Waiting for device screen…" : "Starting capture…")
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
                self.startupMessage = nil
                self.phase = .recording
                self.checkApplicationTargets()
                guard self.phase == .recording else { return }
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
                await self.engine.cancel(expectedSessionID: id)
                guard self.sessionID == id, self.phase != .finishing else { return }
                let recordingError = error as? RecordingError
                self.failedPermission = recordingError?.permissionKind
                self.permissionSettingsURL = recordingError?.permissionKind?.settingsURL
                Log.recording.error(
                    "recording start failed error=\(Log.detail(error)) mode=\(self.configuration.mode.rawValue) microphone=\(String(describing: self.configuration.microphone)) systemAudio=\(self.configuration.capturesSystemAudio)",
                    telemetry: "Recording start failed"
                )
                self.errorMessage = error.localizedDescription
                self.canRetryStart = recordingError == .mobileDeviceNotStreaming || recordingError == .captureNotStarted
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
        accessPreparationTask?.cancel()
        switch phase {
        case .idle:
            return .idle
        case .reviewing:
            review.cancel()
            return .salvaged
        case .trimming:
            return .unsafe("Recording is being trimmed. Wait for it to finish before quitting.")
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
            RecordingApplicationPicker.shared.cancelPending()
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
                let inspection = await RecordingMediaValidator.inspect(stopResult.url)
                if finishMode != .salvage, inspection.hasVideo, inspection.isReadable,
                   stopResult.outcome == .complete || stopResult.outcome == .partial {
                    try self.presentReview(stopResult)
                } else if stagedURLs.count > 1 || finishMode == .salvage {
                    WorkbenchStore.shared.stageRecordedMedia(urls: stagedURLs, sessionID: stopResult.sessionID)
                    self.resetToIdle()
                } else {
                    self.stageCompletedRecording(urls: stagedURLs, sessionID: stopResult.sessionID, hasAudio: inspection.hasAudio)
                    self.resetToIdle()
                }
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

    private func presentReview(_ result: RecordingStopResult) throws {
        try RecordingTrimTransaction.markForReview(result)
        sleepPreventer.stop()
        phase = .reviewing
        updateControls()
        review.present(result: result, onBusy: { [weak self] busy in
            self?.phase = busy ? .trimming : .reviewing
            self?.updateControls()
        }, onComplete: { [weak self] url in
            guard let self else { return }
            Task { @MainActor in
                if let url {
                    let inspection = await RecordingMediaValidator.inspect(url)
                    self.stageCompletedRecording(urls: [url], sessionID: result.sessionID, hasAudio: inspection.hasAudio)
                } else {
                    let journal = RecordingTrimTransaction.manifest(for: result)
                    RecordingSessionManifest.markRegistered(sessionID: journal.sessionID, in: WorkbenchStore.recordingMediaDirectory)
                    self.savedRecordingURL = journal.outputURL
                    self.liveAudioWarning = "Recording saved. Transcription was not started."
                }
                self.resetToIdle()
            }
        })
    }

    private func stageCompletedRecording(urls: [URL], sessionID: UUID?, hasAudio: Bool) {
        if hasAudio {
            WorkbenchStore.shared.stageRecordedMedia(urls: urls, sessionID: sessionID)
        } else {
            if let sessionID { RecordingSessionManifest.markRegistered(sessionID: sessionID.uuidString, in: WorkbenchStore.recordingMediaDirectory) }
            else { RecordingSessionManifest.markRegistered(urls: urls) }
            savedRecordingURL = urls.first
            liveAudioWarning = "Video saved without audio. Add an audio source to transcribe your next recording."
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
            case .camera:
                isAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
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

    private func preparePermissions(requestAudio: Bool = true) async throws {
        if configuration.mode == .mobileDevice {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecordingError.cameraDenied }
        }
        if requestAudio && (configuration.microphone.isEnabled || (configuration.mode == .mobileDevice && configuration.capturesDeviceAudio)) {
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
        var applicationSelection: RecordingApplicationSelection? = nil
    }

    private func pickCaptureSource(preferredBundleIdentifier: String? = nil, preferredProcessID: Int32? = nil) async throws -> PickedSource {
        switch configuration.mode {
        case .mobileDevice:
            guard let id = configuration.mobileDeviceID, RecordingMobileDevices.devices().contains(where: { $0.id == id }) else {
                throw RecordingError.mobileDeviceUnavailable
            }
            return PickedSource(filter: nil, sourceRect: nil, displayID: nil)
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
            if let preferredBundleIdentifier,
               let picked = try await targetedWindow(bundleIdentifier: preferredBundleIdentifier) {
                return picked
            }
            phase = .picking
            updateControls()
            let filter = try await RecordingContentPicker.shared.pick(style: .window)
            try Task.checkCancellation()
            phase = .preparing
            updateControls()
            return PickedSource(filter: filter, sourceRect: nil, displayID: nil)
        case .application:
            return try await pickApplications(bundleIdentifier: preferredBundleIdentifier, processID: preferredProcessID)
        case .region:
            phase = .picking
            updateControls()
            hider.hideWorkbenchWindows()
            didHideApp = true
            let setup = try await DisplayRegionOverlayController.shared.selectRegion(configuration: configuration, devices: devices)
            let selection = setup.selection
            configuration = setup.configuration
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

    private func pickApplications(bundleIdentifier: String?, processID: Int32?) async throws -> PickedSource {
        let content = try await RecordingPermission.shareableContent()
        try Task.checkCancellation()
        let candidates = RecordingApplicationContent.candidates(in: content)
        let preferred: RecordingApplicationCandidate?
        if let bundleIdentifier {
            let matching = candidates.filter {
                $0.application.bundleIdentifier == bundleIdentifier && (processID == nil || $0.id == processID)
            }
            guard !matching.isEmpty else { throw RecordingError.applicationUnavailable }
            preferred = matching.count == 1 ? matching.first : nil
        } else {
            preferred = nil
        }
        let selection: RecordingApplicationSelection
        if let preferred, preferred.displayIDs.count == 1, let displayID = preferred.displayIDs.first {
            selection = RecordingApplicationSelection(displayID: displayID, applications: [preferred.application])
        } else {
            phase = .picking
            updateControls()
            selection = try await RecordingApplicationPicker.shared.pick(content: content, preferred: preferred?.application)
        }
        try Task.checkCancellation()
        let current = try await RecordingPermission.shareableContent()
        try Task.checkCancellation()
        guard RecordingApplicationSelectionResolver.validate(selection, candidates: RecordingApplicationContent.candidates(in: current)) else {
            throw RecordingError.applicationUnavailable
        }
        let filter = try RecordingApplicationContent.filter(selection: selection, content: current, requireAll: true)
        phase = .preparing
        updateControls()
        floatingControls.present(session: self, displayID: selection.displayID)
        return PickedSource(filter: filter, sourceRect: nil, displayID: selection.displayID, applicationSelection: selection)
    }

    /// Only bypasses the picker when the app has one eligible window and full capture access already exists.
    private func targetedWindow(bundleIdentifier: String) async throws -> PickedSource? {
        guard RecordingPermission.tccAllowsScreenCapture() else { return nil }
        let content: SCShareableContent
        do {
            content = try await RecordingPermission.shareableContent()
        } catch {
            try Task.checkCancellation()
            Log.recording.notice("meeting window enumeration failed; using system picker error=\(Log.detail(error))")
            return nil
        }
        try Task.checkCancellation()
        let candidates = content.windows.map { window in
            RecordingWindowCandidate(
                id: window.windowID,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                isOnScreen: window.isOnScreen,
                layer: window.windowLayer,
                frame: window.frame
            )
        }
        guard let windowID = RecordingWindowSelection.unambiguousWindowID(
            in: candidates, bundleIdentifier: bundleIdentifier
        ), let window = content.windows.first(where: { $0.windowID == windowID }) else {
            Log.recording.notice("meeting window unavailable or ambiguous for bundle=\(bundleIdentifier); using system picker")
            return nil
        }
        Log.recording.notice(
            "recording meeting window bundle=\(bundleIdentifier) title=\(window.title ?? "") size=\(Int(window.frame.width))x\(Int(window.frame.height))"
        )
        return PickedSource(
            filter: SCContentFilter(desktopIndependentWindow: window),
            sourceRect: nil,
            displayID: nil
        )
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
        if configuration.capturesPrimaryAudio { audioTracks += 1 }
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
            var lastTargetCheck: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase.isCapturing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.activeApplicationSelection != nil, now - lastTargetCheck >= 1 {
                    lastTargetCheck = now
                    self.checkApplicationTargets()
                    guard self.phase.isCapturing else { return }
                }
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
        startupMessage = nil
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
        activeApplicationSelection = nil
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
            errorMessage = error == .captureApplicationsUnavailable ? nil : error.localizedDescription
            finish(discard: false)
        case .userStopped:
            guard phase.isCapturing else { return }
            pendingStopReason = .systemUserStopped
            errorMessage = "Recording was stopped from the system Screen Recording control."
            finish(discard: false)
        case .captureTargetLost:
            guard phase.isCapturing else { return }
            pendingStopReason = .captureTargetLost
        }
    }

    private func stopReason(for error: RecordingError, fallback: String) -> RecordingStopReason {
        switch error {
        case .diskSpaceLow:
            .diskSpace
        case .microphoneUnavailable:
            .microphoneLost
        case .captureTargetUnavailable, .captureApplicationsUnavailable:
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
        checkApplicationTargets()
        guard phase.isCapturing else { return }
        logStop(reason: "system did wake")
        engine.handleSystemWake()
    }

    private func handleDisplayChange() {
        guard phase.isCapturing, configuration.requiresScreenCapture else { return }
        if let selected = activeApplicationSelection,
           !NSScreen.screens.contains(where: { $0.displayID == selected.displayID }) {
            pendingStopReason = .captureTargetLost
            errorMessage = RecordingError.captureTargetUnavailable.localizedDescription
            finish(discard: false)
            return
        }
        logStop(reason: "display change")
        engine.handleDisplayChange()
    }

    private func checkApplicationTargets(excluding exitedPID: Int32? = nil) {
        guard phase.isCapturing, let selection = activeApplicationSelection else { return }
        // Workspace's runningApplications snapshot can still contain the app
        // while its termination notification is being delivered. Honor that
        // notification directly and also recheck exact PIDs while capturing.
        let running = selection.applications.compactMap { target -> RecordingApplicationTarget? in
            guard target.processID != exitedPID,
                  let app = NSRunningApplication(processIdentifier: target.processID),
                  let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
            return RecordingApplicationTarget(bundleIdentifier: bundleID, processID: app.processIdentifier,
                                              name: app.localizedName ?? bundleID)
        }
        let survivors = selection.survivingApplications(in: running)
        if survivors.isEmpty {
            Log.recording.notice("recording selected applications exited session=\(sessionID.uuidString)")
            pendingStopReason = .captureTargetLost
            finish(discard: false)
        } else if survivors.count < selection.applications.count {
            liveAudioWarning = "An app closed. Recording continues with the remaining selected apps."
        }
    }

    private func recoverInterruptedSessions() async {
        let recovered = RecordingSessionManifest.recoverInterruptedSessions(
            in: WorkbenchStore.recordingMediaDirectory
        )
        guard phase == .idle, let session = recovered.first else { return }
        liveAudioWarning = "A previous recording was recovered after an interruption."
        if session.urls.count == 1,
           session.manifest.status == RecordingSessionManifest.pendingReview || session.manifest.status == RecordingSessionManifest.pendingTrim {
            if let pending = session.manifest.trimPendingPath {
                let url = URL(fileURLWithPath: pending)
                if url.deletingLastPathComponent() == session.manifest.outputURL.deletingLastPathComponent(),
                   url.lastPathComponent.hasPrefix("trim-export-") { try? FileManager.default.removeItem(at: url) }
            }
            let inspection = await RecordingMediaValidator.inspect(session.urls[0])
            guard phase == .idle else { return }
            guard inspection.isReadable, inspection.hasVideo else {
                errorMessage = "Could not preview this recording. The file was kept."
                return
            }
            RecordingTrimTransaction.cleanupCommittedOriginals(session.manifest)
            let result = RecordingStopResult(url: session.urls[0], diagnostics: RecordingSessionDiagnostics(microphone: nil, systemAudio: nil),
                                             warnings: session.manifest.warnings ?? [], sessionID: UUID(uuidString: session.sessionID))
            do { try presentReview(result) }
            catch { errorMessage = error.localizedDescription }
        } else {
            WorkbenchStore.shared.stageRecordedMedia(urls: session.urls, sessionID: UUID(uuidString: session.sessionID))
        }
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
        if configuration.mode == .mobileDevice { return "usbDevice" }
        if configuration.requiresScreenCapture {
            return "stream"
        }
        if configuration.microphone.deviceID == nil {
            return "engine"
        }
        return "microphone"
    }
}
