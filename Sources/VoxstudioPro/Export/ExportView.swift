import SwiftUI
import UniformTypeIdentifiers

enum ExportDestination: String, CaseIterable, Identifiable {
    case video = "Video"
    case timeline = "Timeline"
    case voxStudioProject = "VoxStudio project"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: L10n.key("Export video")
        case .timeline: L10n.key("Send to another editor")
        case .voxStudioProject: L10n.key("Save a project copy")
        }
    }

    var detail: String {
        switch self {
        case .video: "Create a video file that is ready to share."
        case .timeline: "Export a timeline to continue editing in another app. This does not create a playable video."
        case .voxStudioProject: "Save an editable copy with its media included."
        }
    }

    var artifactKind: ExportArtifactKind {
        switch self {
        case .video: .video
        case .timeline: .timeline
        case .voxStudioProject: .project
        }
    }

    var historyTitle: String {
        switch self {
        case .video: "Video exports"
        case .timeline: "Timeline exports"
        case .voxStudioProject: "Project copies"
        }
    }

    var submissionTitle: String {
        switch self {
        case .video: "Export video…"
        case .timeline: "Export timeline…"
        case .voxStudioProject: "Save project copy…"
        }
    }
}

enum TimelineExportFormat: String, CaseIterable, Identifiable {
    case xmeml = "XMEML"
    case fcpxml = "FCPXML"

    var id: String { rawValue }

    var exportFormat: ExportFormat {
        switch self {
        case .xmeml: .xml
        case .fcpxml: .fcpxml
        }
    }

    var summary: String {
        switch self {
        case .xmeml: L10n.key("Older interchange format, best when Premiere Pro is the destination. Supports basic edits and keyframes, but not text, color, effects, edge softness, or edge rounding.")
        case .fcpxml: L10n.key("Newer timeline format with better support for DaVinci Resolve and Final Cut Pro. Supports basic edits, keyframes, and text, but not color, effects, edge softness, or edge rounding.")
        }
    }

}

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var exportQueue = ExportQueue.shared
    @State private var destination: ExportDestination = .video
    @State private var timelineFormat: TimelineExportFormat = .fcpxml
    @State private var fcpxmlVersion: FCPXMLVersion = .default
    @State private var targetEditor: TimelineExportEditor = .resolve
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .matchTimeline
    @State private var submissionError: String?
    @State private var packageSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)
    @State private var selectedTimelineId: String?
    @State private var showAllProjects = false
    @State private var showAllTypes = false
    @State private var historySearch = ""
    @State private var historyFilter: ExportHistoryStatus = .all
    @State private var thumbnail: CGImage?
    @State private var importJob: ExportJob?
    @State private var previewController: ExportVideoPreviewController?

    private var exportTimeline: Timeline {
        selectedTimelineId.flatMap { editor.timeline(for: $0) } ?? editor.timeline
    }

    private var sheetSize: CGSize {
        let available = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(AppTheme.Export.sheetWidthWithLog, available.width - 64),
                      height: min(AppTheme.Export.sheetHeight, available.height - 64))
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    settingsPanel
                    Divider().opacity(0.3)
                    settingsBottomBar
                }
                .frame(width: sheetSize.width * 0.53)
                Divider().opacity(0.3)
                VStack(spacing: 0) {
                    logHeader
                    exportLog
                }
                .frame(maxWidth: .infinity)
                .background(AppTheme.Background.prominentColor.opacity(0.45))
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .appSheetBackground()
        .tint(AppTheme.Export.accent)
        .onChange(of: destination) { _, _ in showAllTypes = false }
        .onChange(of: targetEditor) { _, target in
            timelineFormat = target.defaultFormat == .xml ? .xmeml : .fcpxml
            fcpxmlVersion = .default
        }
        .sheet(item: $importJob) { job in ExportTimelineImportView(job: job) }
        .onDisappear {
            previewController?.close()
            previewController = nil
        }
        .task {
            selectedTimelineId = editor.activeTimelineId
            let entries = editor.mediaManifest.entries
            let projectURL = editor.projectURL
            let summary = await Task.detached(priority: .utility) {
                Self.packageMediaSummary(entries: entries, projectURL: projectURL)
            }.value
            guard !Task.isCancelled else { return }
            packageSummary = summary
        }
        .task(id: destination.rawValue + exportTimeline.id) {
            thumbnail = nil
            guard destination == .video else { return }
            let timeline = exportTimeline
            let urls = editor.mediaResolver.expectedURLMap()
            let resolver = editor.timelineResolver()
            let missing = editor.missingMediaRefs
            let data = await ExportArtifactMetadata.timelineCover(timeline, mediaURLs: urls,
                resolveTimeline: resolver, missingMediaRefs: missing)
            guard !Task.isCancelled else { return }
            if let data { thumbnail = ImageEncoder.thumbnail(data: data, maxPixelSize: 960) }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
                .foregroundStyle(AppTheme.Export.accent)
                .frame(width: AppTheme.zoomed(40), height: AppTheme.zoomed(40))
                .background(AppTheme.Export.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Export"))
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                Text("VoxStudio / " + (editor.projectURL?.deletingPathExtension().lastPathComponent ?? exportTimeline.name))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
            Spacer()
            Button { editor.showExportDialog = false } label: {
                Image(systemName: "xmark").padding(8)
            }.buttonStyle(.plain).accessibilityLabel(L10n.string("Close"))
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                destinationPicker
                VStack(spacing: 0) {
                    if destination != .voxStudioProject {
                        settingRow(label: L10n.string("Timeline")) {
                            Picker("", selection: $selectedTimelineId) {
                                ForEach(editor.timelines) { Text($0.name).tag($0.id as String?) }
                            }.labelsHidden()
                        }
                        Divider()
                    }
                    switch destination {
                    case .video: videoSettings
                    case .timeline: timelineSettings
                    case .voxStudioProject: projectPackageSettings
                    }
                }
                .padding(AppTheme.Spacing.md)
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: 16))
                outputPreview
                if let submissionError {
                    Text(L10n.display(submissionError))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputPreview: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Your output").uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(AppTheme.Background.prominentColor)
                if destination == .video, let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: destinationSymbol(destination))
                        .font(.system(size: 32, weight: .light)).foregroundStyle(AppTheme.Text.mutedColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if destination == .video {
                    Text(formatTimecode(frame: exportTimeline.totalFrames, fps: exportTimeline.fps))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white).padding(6)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)).padding(8)
                }
            }
            .frame(height: AppTheme.zoomed(destination == .video ? 210 : 90))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(outputFilename)
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            exportSummary
            Text(L10n.string(destination == .timeline ? "Choose a save location when you export." : "Estimated size · Choose a save location next"))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.Border.subtleColor.opacity(0.5)))
    }

    private var outputFilename: String {
        if destination == .voxStudioProject {
            return "\(editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName).\(Project.fileExtension)"
        }
        return "\(exportTimeline.name).\(exportFormat.fileExtension)"
    }

    private func destinationSymbol(_ option: ExportDestination) -> String {
        switch option {
        case .video: "play.rectangle"
        case .timeline: "film.stack"
        case .voxStudioProject: "shippingbox"
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("New export").uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label(L10n.string(key: destination.title), systemImage: destinationSymbol(destination))
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    .foregroundStyle(AppTheme.Export.accent)
                Text(L10n.string(key: destination.detail))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Menu {
                    Picker(L10n.string("Export purpose"), selection: $destination) {
                        ForEach(ExportDestination.allCases) { option in
                            Label(L10n.string(key: option.title), systemImage: destinationSymbol(option)).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(L10n.string("More export options"))
                }
                .fixedSize()
                .accessibilityIdentifier("export-purpose-menu")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Export.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var videoSettings: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            settingRow(label: L10n.string("Codec")) {
                Picker(String(), selection: $codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(verbatim: codec.rawValue).tag(codec)
                    }
                }
                .labelsHidden()
            }

            Divider().opacity(AppTheme.Opacity.moderate)

            settingRow(label: L10n.string("Resolution")) {
                Picker(String(), selection: $resolution) {
                    ForEach(ExportResolution.allCases) { resolution in
                        Text(L10n.string(key: resolution.title)).tag(resolution)
                    }
                }
                .labelsHidden()
            }

            Divider().opacity(AppTheme.Opacity.moderate)

            settingRow(label: L10n.string("Frame Rate")) {
                Text(L10n.format("%@ fps", exportTimeline.fps))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private var timelineSettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            settingRow(label: L10n.string("Edit in")) {
                Picker(L10n.string("Edit in"), selection: $targetEditor) {
                    ForEach(TimelineExportEditor.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .labelsHidden()
            }
            DisclosureGroup(L10n.string("Advanced settings")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Picker(L10n.string("Timeline Format"), selection: $timelineFormat) {
                        if targetEditor != .fcp { Text("XMEML (.xml)").tag(TimelineExportFormat.xmeml) }
                        if targetEditor != .premiere { Text("FCPXML (.fcpxml)").tag(TimelineExportFormat.fcpxml) }
                    }
                    if timelineFormat == .fcpxml { fcpxmlVersionRow }
                    Text(L10n.string(key: timelineFormat.summary))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }.padding(.top, AppTheme.Spacing.sm)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var fcpxmlVersionRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Picker(L10n.string("Version"), selection: $fcpxmlVersion) {
                ForEach(FCPXMLVersion.allCases) { version in
                    Text(verbatim: version.rawValue).tag(version)
                }
            }
            .controlSize(.small)
            .font(.system(size: AppTheme.FontSize.xs))
            .fixedSize()
            Text(verbatim: fcpxmlVersion.compatibilityNote)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var projectPackageSettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(L10n.string("Saves a copy of this project with all media bundled inside, so it opens on any machine."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            if packageSummary.missing > 0 {
                Text(packageSummary.missing == 1
                    ? L10n.string("1 media file is missing and will be skipped.")
                    : L10n.format("%@ media files are missing and will be skipped.", packageSummary.missing))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    // MARK: - Export queue

    private var projectQueueID: String {
        editor.exportQueueProjectID
    }

    private var logHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text(L10n.string("Export history"))
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                Spacer()
                Text("\(exportLogJobs.count)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.Background.prominentColor, in: Capsule())
            }
            HStack {
                Text(L10n.string(key: showAllTypes ? "All file types" : destination.historyTitle))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                Spacer()
                Button(L10n.string(showAllTypes ? "Show current type" : "Show all types")) { showAllTypes.toggle() }
                    .buttonStyle(.plain).foregroundStyle(AppTheme.Export.accent)
                    .font(.system(size: AppTheme.FontSize.xs))
            }
            Picker("", selection: $showAllProjects) {
                Text(L10n.string("This project")).tag(false)
                Text(L10n.string("All projects")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("Search exports or projects"), text: $historySearch)
                    .textFieldStyle(.plain)
                if !historySearch.isEmpty {
                    Button { historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(L10n.string("Clear search"))
                }
                Menu {
                    Picker(L10n.string("Status"), selection: $historyFilter) {
                        ForEach(ExportHistoryStatus.allCases, id: \.self) { status in
                            Text(L10n.string(key: status.title)).tag(status)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: historyFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }.menuStyle(.borderlessButton).fixedSize()
                .help(L10n.string("Filter exports"))
                .accessibilityLabel(L10n.string(key: historyFilter.title))
            }
            .padding(10)
            .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: 10))
            if historyFilter != .all {
                Text(L10n.string(key: historyFilter.title))
                    .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .padding(AppTheme.Spacing.lg)
    }

    private var exportLog: some View {
        VStack(spacing: 0) {
            if let error = exportQueue.historyError {
                Text(L10n.string("Export history could not be saved or loaded.") + " " + error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor).padding()
            }
            if exportLogJobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 32, weight: .light))
                    Text(L10n.string(key: emptyHistoryTitle))
                        .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    if !showAllTypes {
                        Text(L10n.string("History follows the selected export purpose."))
                            .font(.system(size: AppTheme.FontSize.sm)).multilineTextAlignment(.center)
                        Button(L10n.string("Show all types")) { showAllTypes = true }
                    }
                    if !historySearch.isEmpty || historyFilter != .all {
                        Button(L10n.string("Clear filters")) { historySearch = ""; historyFilter = .all }
                    }
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        let jobs = exportLogJobs
                        ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                            if index == 0 || libraryGroup(job) != libraryGroup(jobs[index - 1]) {
                                Text(libraryGroup(job).uppercased())
                                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                                    .padding(.top, index == 0 ? 0 : AppTheme.Spacing.sm)
                            }
                            ExportArtifactCard(job: job, queue: exportQueue, performAction: performArtifactAction) { url in
                                editor.showExportDialog = false
                                AppState.shared.openProject(at: url)
                            }
                        }
                    }.padding(AppTheme.Spacing.md)
                }
            }
            Text(L10n.string("History is kept across app launches."))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .padding(AppTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var exportLogJobs: [ExportJob] {
        ExportHistoryFilter(kind: showAllTypes ? nil : destination.artifactKind,
            projectID: showAllProjects ? nil : projectQueueID, search: historySearch, status: historyFilter)
            .apply(to: exportQueue.jobs)
    }

    private var emptyHistoryTitle: String {
        if !historySearch.isEmpty || historyFilter != .all { return "No matching exports" }
        if showAllTypes { return "No exports yet" }
        switch destination {
        case .video: return showAllProjects ? "No exported videos yet" : "This project has no exported videos yet"
        case .timeline: return showAllProjects ? "No exported timelines yet" : "This project has no exported timelines yet"
        case .voxStudioProject: return showAllProjects ? "No project copies yet" : "This project has no exported copies yet"
        }
    }

    private func performArtifactAction(_ job: ExportJob) {
        switch job.primaryAction {
        case .playVideo(let url):
            editor.isPlaying = false
            if previewController == nil { previewController = ExportVideoPreviewController() }
            previewController?.show(url: url)
        case .importTimeline: importJob = job
        case .openProject(let url):
            editor.showExportDialog = false
            AppState.shared.openProject(at: url)
        case nil: break
        }
    }

    private func libraryGroup(_ job: ExportJob) -> String {
        if job.status.isPending { return L10n.string("In progress") }
        if Calendar.current.isDateInToday(job.createdAt) { return L10n.string("Today") }
        if Calendar.current.isDateInYesterday(job.createdAt) { return L10n.string("Yesterday") }
        return job.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLocalization.shared.activeLocale))
    }

    // MARK: - Bottom bar

    private var settingsBottomBar: some View {
        HStack {
            if let url = editor.projectURL {
                Label(url.deletingPathExtension().lastPathComponent, systemImage: "link")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Export.accent)
                    .lineLimit(1).truncationMode(.middle)
                    .help(L10n.string("Linked to source project"))
            }
            Spacer()
            Button(L10n.string("Close")) { editor.showExportDialog = false }
                .keyboardShortcut(.cancelAction)
            Button(L10n.string(key: destination.submissionTitle)) { startExport() }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Export.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private var exportSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { summaryChips }
            VStack(alignment: .leading, spacing: 6) { summaryChips }
        }
    }

    @ViewBuilder private var summaryChips: some View {
        switch destination {
        case .video:
            let out = resolution.renderSize(for: CGSize(width: exportTimeline.width, height: exportTimeline.height))
            summaryChip("\(Int(out.width)) × \(Int(out.height))")
            summaryChip("\(exportTimeline.fps) fps")
            summaryChip(codec.rawValue)
            summaryChip("≈ \(estimatedFileSize)")
        case .timeline:
            summaryChip(targetEditor.displayName)
            summaryChip(L10n.string("Timeline exchange file"))
        case .voxStudioProject:
            summaryChip(L10n.format("%@ timelines", editor.timelines.count))
            summaryChip(L10n.format("%@ media files", editor.mediaManifest.entries.count))
            summaryChip("≈ \(ByteCountFormatter.string(fromByteCount: packageSummary.bytes, countStyle: .file))")
        }
    }

    private func summaryChip(_ title: String) -> some View {
        Text(title).font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(AppTheme.Background.prominentColor, in: Capsule())
    }

    // MARK: - Helpers

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var estimatedFileSize: String {
        let seconds = Double(exportTimeline.totalFrames) / Double(max(1, exportTimeline.fps))
        // Bitrate scales with output pixel area, so any resolution (incl. 2K / native) is covered.
        let out = resolution.renderSize(for: CGSize(width: exportTimeline.width, height: exportTimeline.height))
        let megapixels = Double(out.width * out.height) / 1_000_000
        let bytesPerSecPerMP: Double = switch codec {
        case .h264:   0.63e6
        case .h265:   0.32e6
        case .prores: 9.0e6
        case .hdr:    0.45e6
        }
        let bytesPerSec = bytesPerSecPerMP * max(0.1, megapixels)
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec * seconds), countStyle: .file)
    }

    private var exportFormat: ExportFormat {
        switch destination {
        case .timeline: timelineFormat.exportFormat
        case .voxStudioProject: .xml   // VoxStudio project has its own path; never rendered.
        case .video: codec.exportFormat
        }
    }

    /// Quick estimate for exporting a VoxStudio project package.
    private nonisolated static func packageMediaSummary(
        entries: [MediaManifestEntry],
        projectURL: URL?
    ) -> (collect: Int, missing: Int, bytes: Int64) {
        var collect = 0, missing = 0
        var bytes: Int64 = 0
        for entry in entries {
            let url: URL? = switch entry.source {
            case .external(let path): URL(fileURLWithPath: path)
            case .project(let rel): projectURL?.appendingPathComponent(rel)
            }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            if case .external = entry.source { collect += 1 }
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (collect, missing, bytes)
    }

    private func startExport() {
        if destination == .voxStudioProject { startProjectPackageExport(); return }
        submissionError = nil
        let format = exportFormat
        let timeline = exportTimeline
        let resolution = resolution
        let target = targetEditor
        let version = fcpxmlVersion
        Telemetry.beginOperation("save_panel", data: ["flow": "video_export", "format": format.fileExtension])
        let panel = NSSavePanel()
        let contentType: UTType = switch format {
        case .xml:
            .xml
        case .fcpxml:
            UTType(filenameExtension: "fcpxml") ?? .xml
        case .prores, .hevcHDR:
            .quickTimeMovie
        case .h264, .h265:
            .mpeg4Movie
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(timeline.name).\(format.fileExtension)"

        panel.begin { response in
            Telemetry.endOperation("save_panel")
            guard response == .OK, let url = panel.url else { return }
            do {
                try exportQueue.enqueueVideo(
                    timeline: timeline,
                    resolver: editor.mediaResolver,
                    resolveTimeline: editor.timelineResolver(),
                    format: format,
                    resolution: resolution,
                    fcpxmlVersion: version,
                    fcpxmlTarget: target.fcpxmlTarget,
                    targetEditor: target,
                    missingMediaRefs: editor.missingMediaRefs,
                    outputURL: url,
                    source: .manual,
                    projectID: editor.exportQueueProjectID,
                    analyticsProjectID: editor.projectId,
                    sourceProjectURL: editor.projectURL,
                    coverData: thumbnail.flatMap { ImageEncoder.encodeJPEG($0, quality: 0.8) }
                )
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }

    private func startProjectPackageExport() {
        submissionError = nil
        Telemetry.beginOperation("save_panel", data: ["flow": "project_export"])
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Project.typeIdentifier) ?? .package]
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        panel.nameFieldStringValue = "\(base).\(Project.fileExtension)"

        panel.begin { response in
            Telemetry.endOperation("save_panel")
            guard response == .OK, let url = panel.url else { return }
            do {
                try exportQueue.enqueuePalmierProject(
                    projectFile: editor.projectFileSnapshot(),
                    manifest: editor.mediaManifest,
                    sourceProjectURL: editor.projectURL,
                    outputURL: url,
                    source: .manual,
                    projectID: editor.exportQueueProjectID,
                    analyticsProjectID: editor.projectId,
                    coverData: thumbnail.flatMap { ImageEncoder.encodeJPEG($0, quality: 0.8) }
                )
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}
