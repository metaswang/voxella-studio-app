import SwiftUI
import AVFoundation

/// A cover and metadata snapshot belonging to one export, independent of later project edits.
struct ExportArtifactMetadata: Sendable {
    var cover: Data?
    var bytes: Int64?
    var modifiedAt: Date?
    var createdAt: Date?
    var videoSummary: String?
    var durationSeconds: Double?

    nonisolated static func read(_ url: URL) async -> Self {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey])
        var result = Self(bytes: values?.fileSize.map(Int64.init), modifiedAt: values?.contentModificationDate, createdAt: values?.creationDate)
        if values?.isDirectory == true {
            result.bytes = directoryBytes(url)
            result.cover = ImageEncoder.thumbnail(url: url.appendingPathComponent(Project.thumbnailFilename), maxPixelSize: 320)
                .flatMap { ImageEncoder.encodeJPEG($0, quality: 0.8) }
        } else if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.appliesPreferredTrackTransform = true
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            if duration.isFinite && duration > 0 { result.durationSeconds = duration }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform),
               let fps = try? await track.load(.nominalFrameRate) {
                let display = size.applying(transform)
                let descriptions = try? await track.load(.formatDescriptions)
                let subtype = descriptions?.first.map { CMFormatDescriptionGetMediaSubType($0) }
                let codec: String = switch subtype {
                case kCMVideoCodecType_H264: "H.264"
                case kCMVideoCodecType_HEVC: "HEVC"
                case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
                     kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes4444: "ProRes"
                default: url.pathExtension.uppercased()
                }
                let seconds = duration.isFinite ? max(0, Int(duration)) : 0
                let bitrate = (try? await track.load(.estimatedDataRate)) ?? 0
                result.videoSummary = "\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(Int(abs(display.width)))×\(Int(abs(display.height))) · \(String(format: "%g", fps)) fps · \(codec)"
                if bitrate > 0 {
                    result.videoSummary? += " · \(String(format: "%.1f", bitrate / 1_000_000)) Mbps"
                }
            }
            let time = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                result.cover = ImageEncoder.encodeJPEG(image, quality: 0.8)
            }
        }
        return result
    }
    @concurrent static func timelineCover(
        _ timeline: Timeline,
        mediaURLs: [String: URL],
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>
    ) async -> Data? {
        guard timeline.totalFrames > 0, !Task.isCancelled else { return nil }
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        guard let result = try? await CompositionBuilder.build(
            timeline: timeline, resolveURL: { mediaURLs[$0] }, resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs, renderSize: canvas
        ), !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        let frame = min(max(0, timeline.fps), timeline.totalFrames - 1)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(max(1, timeline.fps)))
        guard let image = try? await generator.image(at: time).image, !Task.isCancelled else { return nil }
        return ImageEncoder.encodeJPEG(image, quality: 0.8)
    }

    private nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let file as URL in files {
                let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if info?.isRegularFile == true { total += Int64(info?.fileSize ?? 0) }
            }
        }
        return total
    }

}

struct ExportArtifactCard: View {
    let job: ExportJob
    let queue: ExportQueue
    let performAction: (ExportJob) -> Void
    let openProject: (URL) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var cover: CGImage?
    @State private var fileExists = false
    @State private var fileChanged = false
    @State private var projectExists = false
    @State private var expanded = false
    @State private var legacyDuration: Double?

    private var projectURL: URL? { job.linkedProjectURL }
    private var projectName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? L10n.string("Source project unavailable")
    }
    private var statusTitle: String {
        switch job.status {
        case .waiting: L10n.string("Queued")
        case .preparing: L10n.string("Preparing")
        case .exporting: L10n.string(job.artifactKind == .video ? "Rendering" : "Exporting")
        case .canceling: L10n.string("Canceling")
        case .completed:
            switch job.artifactKind {
            case .video: L10n.string("Video exported")
            case .timeline: L10n.string("Timeline exported")
            case .project: L10n.string("Project copy saved")
            case .unknown: L10n.string("Completed")
            }
        case .failed: L10n.string("Failed")
        case .canceled: L10n.string("Canceled")
        }
    }
    private var statusColor: Color {
        switch job.status {
        case .completed: AppTheme.Status.successColor
        case .failed: AppTheme.Status.errorColor
        case .waiting, .preparing, .exporting, .canceling: AppTheme.Export.accent
        default: AppTheme.Text.secondaryColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                coverView
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.filename)
                        .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(statusTitle).foregroundStyle(statusColor)
                        if job.status.isRunning {
                            Spacer()
                            Text(job.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                    }.font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    if let summary = visibleSummary {
                        Text(summary).font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let bytes = job.outputBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if job.status.isPending {
                ProgressView(value: job.progress).tint(AppTheme.Export.accent)
            }
            Button {
                if let projectURL { openProject(projectURL) }
            } label: {
                Label(L10n.format("Source project: %@", projectName), systemImage: "arrow.up.forward.app")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            .foregroundStyle(projectExists ? AppTheme.Export.accent : AppTheme.Text.tertiaryColor)
            .disabled(!projectExists)
            .help(projectExists ? L10n.string("Open source project") : L10n.string("Source project unavailable"))
            .accessibilityLabel(L10n.string("Open source project") + ": " + projectName)

            Text(timestamp(job.createdAt, time: .shortened))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) { actions }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) { actions }
            }
            .controlSize(.small)
            if job.status == .completed && !fileExists {
                notice(L10n.string("File moved or deleted"), symbol: "exclamationmark.triangle")
            } else if fileChanged {
                notice(L10n.string("File changed since this export. Actions use the current file."), symbol: "exclamationmark.triangle")
            }
            if let error = job.error { notice(L10n.display(error), symbol: "exclamationmark.circle") }
            if !job.warnings.isEmpty {
                DisclosureGroup(L10n.format("%@ export warnings", job.warnings.count)) {
                    ForEach(Array(job.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(L10n.display(warning)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.system(size: AppTheme.FontSize.sm))
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if let summary = job.mediaSummary { Text(summary) }
                    Text(L10n.string("Exported") + ": " + timestamp(job.createdAt))
                    if let date = job.outputCreatedAt {
                        Text(L10n.string("File created") + ": " + timestamp(date))
                    }
                    if let date = job.outputModifiedAt {
                        Text(L10n.string("File modified") + ": " + timestamp(date))
                    }
                    Text(job.outputURL.path).textSelection(.enabled)
                    Text(L10n.string("Removing history keeps the exported file."))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            job.status.isPending ? AppTheme.Export.accent.opacity(0.25) : AppTheme.Border.subtleColor))
        .task(id: job.coverData) {
            guard job.artifactKind == .video else { return }
            let data = job.coverData
            cover = await Task.detached(priority: .utility) {
                data.flatMap { ImageEncoder.thumbnail(data: $0, maxPixelSize: 320) }
            }.value
        }
        .task(id: job.status) {
            guard job.artifactKind == .video, job.status == .completed,
                  job.artifact?.durationSeconds == nil else { return }
            let seconds = try? await AVURLAsset(url: job.outputURL).load(.duration).seconds
            guard !Task.isCancelled else { return }
            legacyDuration = seconds
        }
        .onAppear { refreshAvailability() }
        .onChange(of: job.status) { _, _ in refreshAvailability() }
        .onChange(of: projectURL) { _, _ in refreshAvailability() }
        .onChange(of: scenePhase) { _, _ in refreshAvailability() }
    }

    private var coverView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(AppTheme.Background.prominentColor)
            if job.artifactKind == .video, let cover {
                Image(decorative: cover, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: job.artifactKind.symbol).font(.system(size: 28, weight: .light))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: AppTheme.zoomed(job.artifactKind == .video ? 120 : 60), height: AppTheme.zoomed(80))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(L10n.string("Export cover"))
    }

    private var visibleSummary: String? {
        switch job.artifactKind {
        case .video:
            guard let seconds = job.artifact?.durationSeconds ?? legacyDuration,
                  seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return L10n.string("Video file") }
            let duration = Int(seconds)
            return "\(duration / 60):\(String(format: "%02d", duration % 60))"
        case .timeline:
            if let target = job.artifact?.targetEditor { return L10n.format("Import into %@", target.displayName) }
            return L10n.string("Timeline file for another video editor")
        case .project:
            if let timelines = job.artifact?.timelineCount, let media = job.artifact?.mediaFileCount {
                return L10n.format("%@ timelines · %@ media files", timelines, media)
            }
            return L10n.string("Editable project copy with bundled media")
        case .unknown: return nil
        }
    }

    @ViewBuilder private var actions: some View {
        if job.status == .completed {
            if let action = job.primaryAction {
                Button {
                    refreshAvailability()
                    guard fileExists else { return }
                    performAction(job)
                } label: {
                    switch action {
                    case .playVideo: Label(L10n.string("Play video"), systemImage: "play.fill")
                    case .importTimeline: Label(L10n.string("Import instructions"), systemImage: "info.circle")
                    case .openProject: Label(L10n.string("Open copy"), systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!fileExists)
            }
            Button(L10n.string("Show in Finder")) {
                refreshAvailability()
                guard fileExists else { return }
                NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
            }.disabled(!fileExists)
        } else if job.status.isPending {
            Button(L10n.string("Cancel Export")) { queue.cancel(job.id) }
                .disabled(job.status == .canceling)
        }
        Menu {
            Button(L10n.string(expanded ? "Hide details" : "Show details")) { expanded.toggle() }
            if job.status.isFinished {
                Divider()
                Button(L10n.string("Remove from history")) { queue.remove(job.id) }
            }
        } label: {
            Label(L10n.string("More"), systemImage: "ellipsis")
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private func timestamp(_ date: Date, time: Date.FormatStyle.TimeStyle = .standard) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: time).locale(AppLocalization.shared.activeLocale))
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Status.errorColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshAvailability() {
        fileExists = FileManager.default.fileExists(atPath: job.outputURL.path)
        if let saved = job.outputModifiedAt,
           let current = try? job.outputURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileChanged = abs(current.timeIntervalSince(saved)) > 1
        } else {
            fileChanged = false
        }
        projectExists = projectURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}
