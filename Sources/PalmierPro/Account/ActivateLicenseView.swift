import AppKit
import SwiftUI

#if !MAC_APP_STORE
struct ActivateLicenseView: View {
    @Bindable private var account = AccountService.shared
    @State private var key = ""
    @State private var isSubmitting = false
    @State private var statusMessage: String?
    @State private var didSucceed = false
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate License")
                .font(.title2.weight(.semibold))
            Text("Paste a Lifetime license key. You must be signed in — the key binds to your account, then this Mac receives a Lifetime device credential.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.userID == nil {
                Text("Sign in first, then return here to activate.")
                    .foregroundStyle(.orange)
                Button("Open Account…") {
                    SettingsWindowController.shared.show(tab: .account)
                }
            } else {
                TextField("VXLT-XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(didSucceed ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button(isSubmitting ? "Activating…" : "Activate") {
                        Task { await activate() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    @MainActor
    private func activate() async {
        isSubmitting = true
        statusMessage = nil
        didSucceed = false
        defer { isSubmitting = false }
        do {
            try await account.redeemLicenseKey(key)
            didSucceed = true
            statusMessage = "Lifetime activated on this account."
            try? await Task.sleep(nanoseconds: 900_000_000)
            onClose()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
final class ActivateLicenseWindowController: NSWindowController {
    static let shared = ActivateLicenseWindowController()
    private var hosting: NSHostingView<AnyView>?

    private init() {
        let root = ActivateLicenseView(onClose: {})
        let hosting = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Activate License"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.hosting = hosting
        super.init(window: window)
        refreshRoot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshRoot()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshRoot() {
        hosting?.rootView = AnyView(
            ActivateLicenseView { [weak self] in
                self?.window?.close()
            }
            .appZoomEnvironment()
            .tint(AppTheme.Accent.primary)
        )
    }
}
#endif
