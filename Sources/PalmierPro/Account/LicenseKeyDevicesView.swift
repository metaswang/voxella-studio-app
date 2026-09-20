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
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("License Key Devices")
                .font(.title2.weight(.semibold))
            Text("This key can be used on up to \(maxDevices) Macs. Unbind a device to free a slot.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading && devices.isEmpty {
                ProgressView("Loading…")
            } else if devices.isEmpty {
                Text("No active devices.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(devicesUsed) / \(maxDevices) devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(devices) { device in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.deviceLabel?.isEmpty == false ? device.deviceLabel! : "Mac")
                                    .font(.body.weight(.medium))
                                Text(device.fingerprintMasked)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if device.isCurrent {
                                    Text("This Mac")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            Button("Unbind") {
                                Task { await unbind(device.fingerprint) }
                            }
                            .disabled(unbindingFingerprint != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 180, maxHeight: 280)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Refresh") { Task { await reload() } }
                    .disabled(isLoading)
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await reload() }
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
        unbindingFingerprint = fingerprint
        statusMessage = nil
        defer { unbindingFingerprint = nil }
        do {
            let response = try await account.unbindLicenseKeyDevice(fingerprint: fingerprint)
            devices = response.devices
            maxDevices = response.maxDevices
            devicesUsed = response.devicesUsed
            if !LicenseKeyLocalCredential.isPresent() {
                onClose()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
