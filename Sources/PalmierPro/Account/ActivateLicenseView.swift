import AppKit
import SwiftUI

#if !MAC_APP_STORE
struct ActivateLicenseView: View {
    @Bindable private var account = AccountService.shared
    @State private var key = ""
    @State private var isSubmitting = false
    @State private var statusMessage: String?
    @State private var didSucceed = false
    @State private var pendingRedeemAfterSignIn = false
    var onClose: () -> Void = {}

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate License")
                .font(.title2.weight(.semibold))
            Text("Paste a Lifetime license key. Sign in is only needed to bind the key to your account — you can enter the key first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.isSignedIn, account.appAccess.license == .lifetime {
                Text("This account already has Lifetime access.")
                    .foregroundStyle(.green)
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                TextField("VXLT-XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isSubmitting)

                if !account.isSignedIn {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to finish activation")
                            .font(.headline)
                        Text("Your key stays in this window. After sign-in, activation continues automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(account.isSigningIn ? "Signing in…" : "Continue with Apple") {
                                Task { await account.signInWithApple() }
                            }
                            .disabled(account.isSigningIn || isSubmitting)
                            Button(account.isSigningIn ? "Signing in…" : "Continue with Google") {
                                Task { await account.signInWithGoogle() }
                            }
                            .disabled(account.isSigningIn || isSubmitting)
                        }
                        Button("Email sign-in…") {
                            SettingsWindowController.shared.show(tab: .account)
                        }
                        .disabled(account.isSigningIn || isSubmitting)
                    }
                    .padding(.top, 4)
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
                    Button(activateButtonTitle) {
                        Task { await activate() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || account.isSigningIn || trimmedKey.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: account.isSignedIn) { _, signedIn in
            guard signedIn, pendingRedeemAfterSignIn, !trimmedKey.isEmpty else { return }
            pendingRedeemAfterSignIn = false
            Task { await activate() }
        }
    }

    private var activateButtonTitle: String {
        if isSubmitting { return "Activating…" }
        if !account.isSignedIn { return "Sign in & Activate" }
        return "Activate"
    }

    @MainActor
    private func activate() async {
        guard !trimmedKey.isEmpty else { return }
        if !account.isSignedIn {
            pendingRedeemAfterSignIn = true
            statusMessage = "Enter your key above, then sign in to bind it to your account."
            didSucceed = false
            return
        }
        isSubmitting = true
        statusMessage = nil
        didSucceed = false
        defer { isSubmitting = false }
        do {
            try await account.redeemLicenseKey(trimmedKey)
            didSucceed = true
            statusMessage = "Lifetime activated on this Mac."
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
