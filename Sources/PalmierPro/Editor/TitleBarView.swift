import SwiftUI

struct EditorChrome: View {
    @Environment(EditorViewModel.self) var editor
    @State private var exportQueue = ExportQueue.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            agentToggleButton

            Text(editor.projectDisplayName)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.zero)

            exportButton
        }
        .padding(.leading, AppTheme.Workbench.windowControlsLeadingInset)
        .padding(.trailing, AppTheme.Spacing.lg)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }

    private var agentToggleButton: some View {
        Button(action: { editor.agentPanelVisible.toggle() }) {
            Image(systemName: editor.agentPanelVisible ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.aiGradient)
                .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(agentToggleHelp)
        .accessibilityLabel(agentToggleHelp)
    }

    private var agentToggleHelp: String {
        editor.agentPanelVisible ? "Hide AI Chat (⌥⌘A)" : "Show AI Chat (⌥⌘A)"
    }

    private var exportButton: some View {
        let jobs = exportQueue.jobs(for: editor.exportQueueProjectID)
        let activeCount = jobs.count { $0.status.isRunning }
        let waitingCount = jobs.count { $0.status == .waiting }

        return Button(action: { editor.showExportDialog = true }) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Group {
                    if activeCount > 0 {
                        exportActivityDot
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .offset(y: -1)
                    }
                }
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                Text("Export")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.IconSize.lg)
            .hoverHighlight()
            .help("Export (⌘E)")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            activeCount == 0 && waitingCount == 0
                ? "Export"
                : "Export, \(activeCount) active, \(waitingCount) waiting"
        )
    }

    private var exportActivityDot: some View {
        PhaseAnimator([false, true]) { dimmed in
            Circle()
                .fill(AppTheme.Status.warningColor)
                .frame(width: AppTheme.Export.activityDotSize, height: AppTheme.Export.activityDotSize)
                .opacity(dimmed ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
        } animation: { _ in
            .easeInOut(duration: AppTheme.Anim.pulse)
        }
        .accessibilityHidden(true)
    }
}

extension EditorViewModel {
    var projectDisplayName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}
