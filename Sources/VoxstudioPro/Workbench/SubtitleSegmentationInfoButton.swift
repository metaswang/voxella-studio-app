import SwiftUI

struct SubtitleSegmentationInfoButton: View {
    var compute: TaskComputeDestination = .local

    @State private var showsInfo = false
    @Bindable private var settings = LLMSettingsStore.shared
    @Bindable private var connections = ProviderConnectivityStore.shared

    private var method: SubtitleSegmentationMethod {
        settings.subtitleSegmentationMethod(connectionStates: connections.states)
    }

    var body: some View {
        Button {
            showsInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("How subtitles are segmented"))
        .help(L10n.string("How subtitles are segmented"))
        .popover(isPresented: $showsInfo, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(L10n.string("Subtitle segmentation"))
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Text(L10n.string("Off by default. Subtitles are segmented after speech recognition only when you select this option. Translation also prepares subtitle cues."))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if compute == .cloud {
                    Label(L10n.string("VoxStudio Cloud"), systemImage: "cloud")
                        .fontWeight(.semibold)
                    Text(L10n.string("Cloud transcription prepares subtitles on the server. The automatic choice below applies when processing on this Mac."))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else {
                    Label(
                        L10n.string(method == .llm ? "When enabled: LLM refinement" : "When enabled: Local captions"),
                        systemImage: method == .llm ? "sparkles" : "desktopcomputer"
                    )
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                Divider()
                explanation(
                    title: "LLM refinement",
                    detail: "Automatically uses your subtitle model when BYOK is enabled, its provider is Connected, and the Subtitle cleanup model is configured. Refines breaks by meaning and restores punctuation when needed.",
                    icon: "sparkles"
                )
                explanation(
                    title: "Local captions",
                    detail: "Otherwise, uses the same algorithm as Generate Local Captions in Video Editor. Splits by punctuation and readable length, using word timestamps when available. Runs on your Mac without an API key or AI credits; keeps the recognized wording.",
                    icon: "desktopcomputer"
                )
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppTheme.Spacing.lg)
            .frame(width: AppTheme.zoomed(360))
        }
        .task { await refreshConnections() }
        .onReceive(NotificationCenter.default.publisher(for: .aiConfigurationDidChange)) { _ in
            Task { await refreshConnections() }
        }
    }

    private func explanation(title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label(L10n.string(key: title), systemImage: icon)
                .fontWeight(.semibold)
            Text(L10n.string(key: detail))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private func refreshConnections() async {
        guard settings.useBYOK else { return }
        _ = await settings.credentialAvailable()
        await connections.refresh(settings: settings)
    }
}
