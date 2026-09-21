import SwiftUI

extension MediaTab {
    var searchIndexStatus: some View {
        MediaSearchIndexStatus(search: editor.searchIndex, mediaAssets: editor.mediaAssets)
    }
}

private struct MediaSearchIndexStatus: View {
    let search: SearchIndexCoordinator
    let mediaAssets: [MediaAsset]

    @ViewBuilder
    var body: some View {
        let model = VisualModelLoader.shared
        switch model.state {
        case .notInstalled where model.enabled && hasIndexableAssets:
            statusButton(icon: "sparkle.magnifyingglass", label: L10n.string("Download and enable smart search")) {
                model.download()
            }
            .help(L10n.format("Downloads %@ of local resources so you can search media visually.", modelSizeLabel))
        case .downloading(let fraction):
            HStack(spacing: AppTheme.Spacing.sm) {
                statusIndicator(L10n.format("Downloading %@%%", Int(fraction * 100)),
                                help: L10n.string("Downloading the local resources that powers visual search."),
                                progress: fraction)
                Button(L10n.string("Cancel")) { model.cancelDownload() }
                    .buttonStyle(.borderless)
                    .font(.system(size: AppTheme.FontSize.xs))
            }
        case .preparing:
            statusIndicator(L10n.string("Preparing…"), help: L10n.string("Getting smart search ready."))
        case .ready where search.searchFailure != nil:
            Label(L10n.string("Search unavailable"), systemImage: "exclamationmark.triangle")
                .help(L10n.string("Smart search is temporarily unavailable. Try again later."))
                .foregroundStyle(AppTheme.Status.errorColor)
        case .ready where search.indexingActive:
            statusIndicator(L10n.format(
                "Indexing %@/%@",
                min(search.batchCompleted + 1, search.batchTotal),
                search.batchTotal
            ),
                            help: L10n.string("Analyzing media so you can search it."),
                            progress: search.indexingProgress)
        case .failed where model.enabled:
            statusButton(icon: "exclamationmark.triangle", label: L10n.string("Retry")) { model.download() }
                .help(L10n.string("Smart search could not be prepared. Check your connection and try again."))
        default:
            EmptyView()
        }
    }

    private var hasIndexableAssets: Bool {
        mediaAssets.contains { $0.type == .video || $0.type == .image }
    }

    private var modelSizeLabel: String {
        SearchIndexConfig.model.sizeLabel
    }

    private func statusButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
    }

    private func statusIndicator(_ label: String, help: String, progress: Double? = nil) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let progress {
                progressRing(progress)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .help(help)
    }

    private func progressRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.medium)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.03))
                .stroke(AppTheme.Text.secondaryColor,
                        style: StrokeStyle(lineWidth: AppTheme.BorderWidth.medium, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
        .animation(.linear(duration: AppTheme.Anim.transition), value: value)
    }
}
