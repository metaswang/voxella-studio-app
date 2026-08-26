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
        guard let session, session.phase.isCapturing else {
            remove()
            return
        }
        if statusItem == nil {
            rebuild()
        }
        statusItem?.button?.title = buttonTitle(for: session)
        rebuildMenu()
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func rebuild() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: "record.circle.fill",
            accessibilityDescription: "Recording"
        )
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.contentTintColor = AppTheme.Status.error
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let session, session.phase.isCapturing else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: session.isPaused
                ? "Paused  \(RecordingTimeFormat.clock(session.elapsed))"
                : "Recording  \(RecordingTimeFormat.clock(session.elapsed))",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = true
        menu.addItem(stop)

        let pause = NSMenuItem(
            title: session.isPaused ? "Resume Recording" : "Pause Recording",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        pause.isEnabled = true
        menu.addItem(pause)

        if session.configuration.microphone.isEnabled {
            let mute = NSMenuItem(
                title: session.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
                action: #selector(toggleMute),
                keyEquivalent: ""
            )
            mute.target = self
            mute.isEnabled = true
            menu.addItem(mute)
        }

        menu.addItem(.separator())
        let discard = NSMenuItem(title: "Discard Recording", action: #selector(discardRecording), keyEquivalent: "")
        discard.target = self
        discard.isEnabled = true
        menu.addItem(discard)

        statusItem?.menu = menu
    }

    private func buttonTitle(for session: RecordingSessionController) -> String {
        let prefix = session.isPaused ? "❚❚" : "●"
        return " \(prefix) \(RecordingTimeFormat.clock(session.elapsed))"
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
