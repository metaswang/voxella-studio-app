import SwiftUI

struct ExportTimelineImportView: View {
    let job: ExportJob
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var fileMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("Import instructions"), systemImage: "doc.text")
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
            Text(job.filename).font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .textSelection(.enabled)
            if let target = job.artifact?.targetEditor {
                Text(L10n.format("Import into %@", target.displayName))
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Text(L10n.format("1. Open a project in %@.", target.displayName))
            } else {
                Text(L10n.string("The target editor was not saved with this older export."))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(L10n.string("1. Open a video editor that supports this timeline format."))
            }
            Text(L10n.string("2. Use the editor's timeline or XML import command."))
            Text(L10n.string("3. Select this file. Keep the original media available so the editor can find it."))
            Text(L10n.string("This is a timeline exchange file. To watch or share a video, choose Export video instead."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: 10))
            Text(job.outputURL.path).font(.system(size: AppTheme.FontSize.xs))
                .textSelection(.enabled).foregroundStyle(AppTheme.Text.tertiaryColor)
            if fileMissing {
                Label(L10n.string("File moved or deleted"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            HStack {
                Button(L10n.string("Show in Finder")) {
                    fileMissing = !FileManager.default.fileExists(atPath: job.outputURL.path)
                    if !fileMissing { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) }
                }
                Button(L10n.string(copied ? "Copied" : "Copy path")) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(job.outputURL.path, forType: .string)
                }
                Spacer()
                Button(L10n.string("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: AppTheme.FontSize.sm))
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.zoomed(540))
        .appSheetBackground()
        .onExitCommand { dismiss() }
    }
}
