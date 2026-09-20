import AppKit
import SwiftUI

#if !MAC_APP_STORE
struct ActivateLicenseView: View {
    @Bindable private var account = AccountService.shared
    @State private var key = ""
    @State private var isSubmitting = false
    @State private var statusMessage: String?
    @State private var didSucceed = false
    @State private var showDevices = false
    var onClose: () -> Void = {}

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var alreadyLicensed: Bool {
        account.appAccess.license == .lifetime
            || LifetimeLocalCredential.isPresent()
            || LicenseKeyLocalCredential.isPresent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate License")
                .font(.title2.weight(.semibold))
            Text("Paste your license key to unlock this Mac. Sign-in is optional and only links the key to your account for device management.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if alreadyLicensed {
                Text("This Mac already has Lifetime access.")
                    .foregroundStyle(.green)
                HStack {
                    if LicenseKeyLocalCredential.isPresent() {
                        Button("Manage Devices…") { showDevices = true }
                    }
                    Button("Done") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
                .sheet(isPresented: $showDevices) {
                    LicenseKeyDevicesView(onClose: { showDevices = false })
                }
            } else {
                TextField("VXLT-XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isSubmitting)

                if !account.isSignedIn {
                    Text("Optional: sign in later to manage devices across Macs from your account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let statusMessage {
                    ScrollView {
                        Text(statusMessage)
                            .foregroundStyle(didSucceed ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button(isSubmitting ? "Activating…" : "Activate") {
                        Task { await activate() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || trimmedKey.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @MainActor
    private func activate() async {
        guard !trimmedKey.isEmpty else { return }
        isSubmitting = true
        statusMessage = nil
        didSucceed = false
        defer { isSubmitting = false }
        do {
            try await account.redeemLicenseKey(trimmedKey)
            didSucceed = true
            statusMessage = "License activated on this Mac."
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
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
