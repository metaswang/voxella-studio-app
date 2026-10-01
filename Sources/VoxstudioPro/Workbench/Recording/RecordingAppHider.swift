import AppKit
import Foundation

@MainActor
final class RecordingAppHider {
    private var hiddenWindows: [NSWindow] = []
    private var previousPolicy: NSApplication.ActivationPolicy = .regular
    private var isHiding = false

    func hideWorkbenchWindows() {
        guard !isHiding else { return }
        isHiding = true
        previousPolicy = NSApp.activationPolicy()
        hiddenWindows = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            if window.level >= .statusBar { return false }
            return true
        }
        for window in hiddenWindows {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func restore() {
        guard isHiding else { return }
        isHiding = false
        NSApp.setActivationPolicy(previousPolicy)
        for window in hiddenWindows {
            window.orderFront(nil)
        }
        hiddenWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }
}
