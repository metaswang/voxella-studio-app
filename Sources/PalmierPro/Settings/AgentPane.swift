import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "Model Context Protocol") {
                mcpSection
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Local MCP Server")
                    .font(.system(
                        size: AppTheme.FontSize.md,
                        weight: AppTheme.FontWeight.medium
                    ))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text("Lets external clients such as Codex, Claude, and Cursor inspect and edit the active Voxella Studio project.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(
                        (appState.mcpService?.isRunning ?? false)
                            ? AppTheme.Status.successColor
                            : AppTheme.Text.mutedColor
                    )
                    .frame(
                        width: AppTheme.Spacing.smMd,
                        height: AppTheme.Spacing.smMd
                    )

                if appState.mcpService?.isRunning ?? false {
                    Text("Running on")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("127.0.0.1:\(String(MCPService.port))")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { MCPService.isEnabledPreference },
                        set: { appState.setMCPEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("MCP Server")
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Button {
                HelpWindowController.shared.show(tab: .mcp)
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text("Setup Instructions")
                    Image(systemName: "arrow.up.right")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Accent.link)
            .pointerStyle(.link)

            Label(
                "The server binds only to IPv4 loopback and is not exposed to the local network.",
                systemImage: "lock.shield"
            )
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
