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
            addHeader(L10n.string("VoxStudio Recording"), to: menu)
            menu.addItem(.separator())
            addItem(L10n.string("Record Screen"), action: #selector(recordDisplay), to: menu)
            addItem(L10n.string("Record Window"), action: #selector(recordWindow), to: menu)
            addItem(L10n.string("Record Selected Area"), action: #selector(recordRegion), to: menu)
            addItem(L10n.string("Record Audio Only"), action: #selector(recordAudio), to: menu)
            addItem(
                L10n.string("Voice Input…"),
                action: #selector(showVoiceInput),
                to: menu,
                keyEquivalent: VoiceInputShortcutPreferences.shared.option
            )
            menu.addItem(.separator())
            addItem(L10n.string("Recording Setup…"), action: #selector(showRecordingSetup), to: menu)
            menu.addItem(.separator())
            addHeader(L10n.string("VoxStudio Workflows"), to: menu)
            menu.addItem(.separator())
            addSubmenu(
                L10n.string("Transcribe"),
                imageName: "text.bubble",
                items: [
                    (L10n.string("Import"), #selector(importMedia), "square.and.arrow.down"),
                    (L10n.string("Net Video"), #selector(importNetVideo), "play.rectangle"),
                ],
                to: menu
            )
            addItem(
                L10n.string("Voiceover"),
                action: #selector(showVoiceover),
                to: menu,
                imageName: "waveform.and.mic"
            )
            addItem(
                L10n.string("Remote Meeting Notetaker"),
                action: #selector(showMeetingNotetaker),
                to: menu,
                imageName: "person.2"
            )

        case .preparing, .picking, .finishing:
            addHeader(
                L10n.string(session.phase == .finishing ? "Finishing Recording…" : "Preparing Recording…"),
                to: menu
            )
            menu.addItem(.separator())
            addItem(L10n.string("Cancel Recording"), action: #selector(discardRecording), to: menu)
            addItem(L10n.string("Show Recording Controls"), action: #selector(showRecordingSetup), to: menu)

        case .recording, .paused:
            addHeader(
                session.isPaused
                    ? L10n.format("Paused %@", RecordingTimeFormat.clock(session.elapsed))
                    : L10n.format("Recording %@", RecordingTimeFormat.clock(session.elapsed)),
                to: menu
            )
            menu.addItem(.separator())
            addItem(L10n.string("Stop Recording"), action: #selector(stopRecording), to: menu)
            addItem(
                L10n.string(session.isPaused ? "Resume Recording" : "Pause Recording"),
                action: #selector(togglePause),
                to: menu
            )
            if session.configuration.microphone.isEnabled {
                addItem(
                    L10n.string(session.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone"),
                    action: #selector(toggleMute),
                    to: menu
                )
            }
            menu.addItem(.separator())
            addItem(L10n.string("Show Recording Controls"), action: #selector(showRecordingSetup), to: menu)
            addItem(L10n.string("Discard Recording"), action: #selector(discardRecording), to: menu)
        }

        menu.addItem(.separator())
        addItem(L10n.format("Quit %@", AppIdentity.productName), action: #selector(quitApplication), to: menu)

        statusItem?.menu = menu
    }

    private func configureButton(for session: RecordingSessionController) {
        guard let statusItem else { return }
        let isCapturing = session.phase.isCapturing
        statusItem.button?.image = WorkbenchBrandIcon.statusBarImage()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.contentTintColor = nil
        let applications = session.activeApplicationSelection?.applications.map(\.name).joined(separator: ", ")
        statusItem.button?.toolTip = L10n.string(isCapturing ? "Recording controls" : "Start a recording")
            + (isCapturing && applications?.isEmpty == false ? " · " + (applications ?? "") : "")
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
        keyEquivalent: VoiceInputShortcutOption? = nil,
        imageName: String? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent == nil ? "" : " ")
        if let keyEquivalent {
            item.keyEquivalentModifierMask = keyEquivalent.menuModifiers
        }
        if let imageName {
            item.image = menuImage(named: imageName)
        }
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addSubmenu(
        _ title: String,
        imageName: String,
        items: [(String, Selector, String)],
        to menu: NSMenu
    ) {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for (itemTitle, action, itemImageName) in items {
            addItem(itemTitle, action: action, to: submenu, imageName: itemImageName)
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = menuImage(named: imageName)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func menuImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
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

    @objc private func importMedia() {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        Task { @MainActor in
            let urls = await WorkbenchFilePicker.pickMediaFiles()
            if !urls.isEmpty {
                WorkbenchStore.shared.stageMediaImport(urls)
            }
        }
    }

    @objc private func importNetVideo() {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        WorkbenchStore.shared.showNetVideoImport()
    }

    @objc private func showVoiceover() {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        Task { @MainActor in
            _ = await WorkbenchStore.shared.addDubAfterAccess()
        }
    }

    @objc private func showMeetingNotetaker() {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.showHome()
        WorkbenchStore.shared.route = .meetBot
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

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
