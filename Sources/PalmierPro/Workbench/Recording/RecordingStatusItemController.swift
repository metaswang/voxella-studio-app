import AppKit
import Foundation

@MainActor
final class RecordingStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var session: RecordingSessionController?

    func attach(_ session: RecordingSessionController) {
        self.session = session
        rebuild()
    }

    func update() {
        guard let session else { return }
        if statusItem == nil {
            rebuild()
        }
        configureButton(for: session)
        rebuildMenu()
    }

    private func rebuild() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        guard let session else { return }
        configureButton(for: session)
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let session else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch session.phase {
        case .idle:
            addHeader("VoxStudio Recording", to: menu)
            menu.addItem(.separator())
            addItem("Record Screen", action: #selector(recordDisplay), to: menu)
            addItem("Record Window", action: #selector(recordWindow), to: menu)
            addItem("Record Selected Area", action: #selector(recordRegion), to: menu)
            addItem("Record Audio Only", action: #selector(recordAudio), to: menu)
            addItem(
                "Voice Input…",
                action: #selector(showVoiceInput),
                to: menu,
                keyEquivalent: VoiceInputShortcutPreferences.shared.option
            )
            menu.addItem(.separator())
            addItem("Recording Setup…", action: #selector(showRecordingSetup), to: menu)

        case .preparing, .picking, .finishing:
            addHeader(session.phase == .finishing ? "Finishing Recording…" : "Preparing Recording…", to: menu)
            menu.addItem(.separator())
            addItem("Cancel Recording", action: #selector(discardRecording), to: menu)
            addItem("Show Recording Controls", action: #selector(showRecordingSetup), to: menu)

        case .recording, .paused:
            addHeader(
                session.isPaused
                    ? "Paused  \(RecordingTimeFormat.clock(session.elapsed))"
                    : "Recording  \(RecordingTimeFormat.clock(session.elapsed))",
                to: menu
            )
            menu.addItem(.separator())
            addItem("Stop Recording", action: #selector(stopRecording), to: menu)
            addItem(
                session.isPaused ? "Resume Recording" : "Pause Recording",
                action: #selector(togglePause),
                to: menu
            )
            if session.configuration.microphone.isEnabled {
                addItem(
                    session.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
                    action: #selector(toggleMute),
                    to: menu
                )
            }
            menu.addItem(.separator())
            addItem("Show Recording Controls", action: #selector(showRecordingSetup), to: menu)
            addItem("Discard Recording", action: #selector(discardRecording), to: menu)
        }

        statusItem?.menu = menu
    }

    private func configureButton(for session: RecordingSessionController) {
        guard let statusItem else { return }
        let isCapturing = session.phase.isCapturing
        statusItem.button?.image = WorkbenchBrandIcon.statusBarImage()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = isCapturing ? "Recording controls" : "Start a recording"
        statusItem.button?.title = isCapturing ? " \(RecordingTimeFormat.clock(session.elapsed))" : ""
        statusItem.length = isCapturing ? NSStatusItem.variableLength : NSStatusItem.squareLength
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    private func addItem(
        _ title: String,
        action: Selector,
        to menu: NSMenu,
        keyEquivalent: VoiceInputShortcutOption? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent == nil ? "" : " ")
        if let keyEquivalent {
            item.keyEquivalentModifierMask = keyEquivalent.menuModifiers
        }
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func recordDisplay() {
        session?.start(mode: .display)
    }

    @objc private func recordWindow() {
        session?.start(mode: .window)
    }

    @objc private func recordRegion() {
        session?.start(mode: .region)
    }

    @objc private func recordAudio() {
        session?.start(mode: .audioOnly)
    }

    @objc private func showVoiceInput() {
        VoiceInputCoordinator.shared.present()
    }

    @objc private func showRecordingSetup() {
        session?.showRecordingSetup()
    }

    @objc private func stopRecording() {
        session?.stop()
    }

    @objc private func togglePause() {
        session?.togglePause()
    }

    @objc private func toggleMute() {
        session?.toggleMicrophoneMuted()
    }

    @objc private func discardRecording() {
        session?.discard()
    }
}
