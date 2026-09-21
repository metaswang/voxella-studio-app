import SwiftUI

#if !MAC_APP_STORE
struct LicenseKeyDevicesView: View {
    @Bindable private var account = AccountService.shared
    @State private var devices: [LicenseKeyDeviceAPIItem] = []
    @State private var maxDevices = 0
    @State private var devicesUsed = 0
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var unbindingFingerprint: String?
    @State private var confirmUnbindDevice: LicenseKeyDeviceAPIItem?
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("License Key Devices"))
                .font(.title2.weight(.semibold))
            Text(L10n.format("This key can be used on up to %d Macs. Unbind a device to free a slot.", maxDevices))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading && devices.isEmpty {
                ProgressView(L10n.string("Loading…"))
            } else if devices.isEmpty {
                Text(L10n.string("No active devices."))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.format("%d / %d devices", devicesUsed, maxDevices))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(devices) { device in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.deviceLabel?.isEmpty == false ? device.deviceLabel! : L10n.string("Mac"))
                                    .font(.body.weight(.medium))
                                Text(device.fingerprintMasked)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if device.isCurrent {
                                    Text(L10n.string("This Mac"))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            Button(L10n.string("Unbind")) {
                                confirmUnbindDevice = device
                            }
                            .disabled(unbindingFingerprint != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 180, maxHeight: 280)
            }

            if let statusMessage {
                Text(L10n.display(statusMessage))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("Refresh")) { Task { await reload() } }
                    .disabled(isLoading)
                Button(L10n.string("Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await reload() }
        .alert(L10n.string("Unbind Device?"), isPresented: .constant(confirmUnbindDevice != nil), presenting: confirmUnbindDevice) { device in
            Button(L10n.string("Cancel"), role: .cancel) {
                confirmUnbindDevice = nil
            }
            Button(L10n.string("Unbind"), role: .destructive) {
                let fingerprint = device.fingerprint
                confirmUnbindDevice = nil
                Task { await unbind(fingerprint) }
            }
        } message: { device in
            Text(L10n.string(device.isCurrent
                ? "This will free a device slot for this license key. This Mac will lose Lifetime access."
                : "This will free a device slot for this license key. The device will need to be re-activated to regain access."))
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }
        do {
            let response = try await account.listLicenseKeyDevices()
            devices = response.devices
            maxDevices = response.maxDevices
            devicesUsed = response.devicesUsed
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func unbind(_ fingerprint: String) async {
        let currentFingerprint = try? DeviceFingerprint.current()
        let isUnbindingThisMac = (currentFingerprint == fingerprint)
        
        unbindingFingerprint = fingerprint
        statusMessage = nil
        defer { unbindingFingerprint = nil }
        do {
            let response = try await account.unbindLicenseKeyDevice(fingerprint: fingerprint)
            devices = response.devices
            maxDevices = response.maxDevices
            devicesUsed = response.devicesUsed
            if isUnbindingThisMac {
                onClose()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
