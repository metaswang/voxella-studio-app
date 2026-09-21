import SwiftUI

struct RecordingPane: View {
    @State private var listenEnhanceEnabled: Bool = ListenEnhanceSettings.isEnabled
    @State private var cloudRepairEnabled: Bool = CloudVocalRepairSettings.isEnabled
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsToggleRow(
                title: "Enhance for listening",
                subtitle: "After recording stops, build a clearer listen track for playback and export. Transcription always uses the untouched master.",
                isOn: $listenEnhanceEnabled
            )

            SettingsToggleRow(
                title: "Cloud High-Fidelity Voice Repair",
                subtitle: cloudRepairSubtitle,
                isOn: Binding(
                    get: { cloudRepairEnabled && canUseCloudRepair },
                    set: { newValue in
                        guard canUseCloudRepair else { return }
                        cloudRepairEnabled = newValue
                        CloudVocalRepairSettings.isEnabled = newValue
                    }
                )
            )
            .disabled(!canUseCloudRepair)
            if !canUseCloudRepair {
                Text(cloudRepairSubtitle)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .onAppear {
            listenEnhanceEnabled = ListenEnhanceSettings.isEnabled
            cloudRepairEnabled = CloudVocalRepairSettings.isEnabled
        }
        .onChange(of: listenEnhanceEnabled) { _, newValue in
            ListenEnhanceSettings.isEnabled = newValue
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn {
                cloudRepairEnabled = false
                CloudVocalRepairSettings.isEnabled = false
            }
        }
    }

    private var canUseCloudRepair: Bool { account.canUseCloudHighFidelityVoiceRepair }

    private var cloudRepairSubtitle: String {
        if !account.isSignedIn { return L10n.string("Sign in to enable cloud high-fidelity voice repair.") }
        if !account.isPaid { return L10n.string("Upgrade to Starter or higher to enable cloud high-fidelity voice repair.") }
        if let seconds = account.cloudBillingBalance?.estimatedSeconds[CloudUsageEstimate.vocalRepairUsageType] {
            return L10n.format(
                "After recording, create a clearer repaired track for playback and audio export. Remaining Credits cover about %@ of repair.",
                CloudUsageEstimate.formatDuration(seconds)
            )
        }
        return L10n.string("After recording, create a clearer repaired track for playback and audio export. Transcription always uses the untouched master.")
    }
}
