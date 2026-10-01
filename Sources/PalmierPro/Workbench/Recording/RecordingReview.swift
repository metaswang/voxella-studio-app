import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AVKit
import Observation
import SwiftUI

/// The original remains owned by its journal until a validated replacement and
/// its new path are durable. Deletions are limited to files from this session.
enum RecordingTrimTransaction {
    static func manifest(for result: RecordingStopResult) -> RecordingSessionManifest {
        let journalURL = RecordingSessionManifest.manifestURL(for: result.url)
        if let data = try? Data(contentsOf: journalURL),
           let manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data) { return manifest }
        let directory = result.url.deletingLastPathComponent()
        let recovered = RecordingSessionManifest.recoverInterruptedSessions(in: directory)
        if let match = recovered.first(where: { $0.manifest.outputURL == result.url }) { return match.manifest }
        return RecordingSessionManifest(sessionID: (result.sessionID ?? UUID()).uuidString, startedAt: Date(),
                                        outputPath: result.url.path, mode: "video", backend: "recording",
                                        status: RecordingSessionManifest.pendingReview)
    }

    static func markForReview(_ result: RecordingStopResult) throws {
        var manifest = manifest(for: result)
        manifest.status = RecordingSessionManifest.pendingReview
        try RecordingSessionManifest.writeThrowing(manifest)
    }

    static func commit(result: RecordingStopResult, range: ClosedRange<Double>) async throws -> URL {
        var journal = manifest(for: result)
        let source = result.url
        let directory = source.deletingLastPathComponent()
        let token = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-trimmed-\(token).mp4")
        let temporary = directory.appendingPathComponent("trim-export-\(UUID().uuidString).mp4")
        journal.journalPath = journal.manifestURL.path
        journal.trimPendingPath = temporary.path
        journal.trimStart = range.lowerBound
        journal.trimEnd = range.upperBound
        let originals = Set([source.path] + result.segmentURLs.map(\.path) + (journal.segments?.map(\.path) ?? []))
        journal.trimDiscardPaths = Array(originals)
        journal.status = RecordingSessionManifest.pendingTrim
        try RecordingSessionManifest.writeThrowing(journal)
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        try await MediaRangeExtractor.extract(sourceURL: source, range: range, destinationURL: temporary, precision: .frameAccurate)
        try Task.checkCancellation()
        let inspection = await RecordingMediaValidator.inspect(temporary)
        let sourceInspection = await RecordingMediaValidator.inspect(source)
        guard inspection.isReadable, inspection.hasVideo,
              !sourceInspection.hasAudio || inspection.hasAudio,
              let duration = inspection.duration,
              abs(duration - (range.upperBound - range.lowerBound)) <= 0.15 else {
            throw RecordingError.writerFailed("The trimmed recording could not be verified. The original was kept.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        journal.outputPath = destination.path
        journal.trimPendingPath = nil
        journal.status = RecordingSessionManifest.pendingReview
        journal.segments = nil
        do { try RecordingSessionManifest.writeThrowing(journal) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        committed = true
        cleanupCommittedOriginals(journal)
        return destination
    }

    static func cleanupCommittedOriginals(_ journal: RecordingSessionManifest) {
        guard journal.status != RecordingSessionManifest.pendingTrim else { return }
        let directory = journal.outputURL.deletingLastPathComponent().standardizedFileURL
        for path in journal.trimDiscardPaths ?? [] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url != journal.outputURL.standardizedFileURL,
                  url.deletingLastPathComponent() == directory else { continue }
            try? FileManager.default.removeItem(at: url)
            let sidecar = RecordingSessionManifest.manifestURL(for: url)
            if sidecar != journal.manifestURL { try? FileManager.default.removeItem(at: sidecar) }
        }
    }
}

@MainActor
final class RecordingReviewController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: RecordingReviewModel?

    func present(result: RecordingStopResult, onBusy: @escaping (Bool) -> Void,
                 onComplete: @escaping (URL?) -> Void) {
        let model = RecordingReviewModel(result: result, onBusy: onBusy) { [weak self] url in
            self?.window?.orderOut(nil)
            self?.window?.contentView = nil
            self?.window?.close()
            self?.window = nil
            self?.model = nil
            onComplete(url)
        }
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = result.url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 440)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingReviewView(model: model).appLocalization().appZoomEnvironment())
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.load()
    }
    func show() { window?.makeKeyAndOrderFront(nil) }
    func cancel() { model?.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        if model.busy { return false }
        model.cancel()
        return false
    }
}

@Observable @MainActor
final class RecordingReviewModel {
    let result: RecordingStopResult
    @ObservationIgnored let playerView = AVPlayerView()
    var busy = false
    var ready = false
    var message: String?
    private var closed = false
    private var duration: Double = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let onBusy: (Bool) -> Void
    @ObservationIgnored private let onComplete: (URL?) -> Void

    init(result: RecordingStopResult, onBusy: @escaping (Bool) -> Void, onComplete: @escaping (URL?) -> Void) {
        self.result = result
        self.onBusy = onBusy
        self.onComplete = onComplete
        message = result.warnings.first
        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: result.url)
    }
    func load() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                duration = try await AVURLAsset(url: result.url).load(.duration).seconds
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if playerView.player?.currentItem?.status == .failed {
                        throw RecordingError.captureFailed("Could not preview this recording. The file was kept.")
                    }
                    if playerView.player?.currentItem?.status == .readyToPlay, playerView.canBeginTrimming {
                        ready = true
                        playerView.beginTrimming { [weak self] selection in
                            Task { @MainActor [weak self] in self?.handleTrim(selection) }
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                ready = true
                message = "Trimming is unavailable for this file. You can keep the full recording."
            } catch is CancellationError { }
            catch { message = error.localizedDescription; ready = true }
        }
    }
    private func handleTrim(_ selection: AVPlayerViewTrimResult) {
        guard !closed, !busy else { return }
        guard selection == .okButton else { cancel(); return }
        guard let item = playerView.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
        let end = item.forwardPlaybackEndTime.isNumeric ? min(duration, item.forwardPlaybackEndTime.seconds) : duration
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            message = "Choose a non-empty time range."
            return
        }
        if start <= 0, end >= duration { finish(result.url); return }
        playerView.player?.pause()
        busy = true
        onBusy(true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await RecordingTrimTransaction.commit(result: result, range: start...end)
                finish(url)
            } catch is CancellationError {
                busy = false
                onBusy(false)
                finish(nil)
            } catch {
                busy = false
                onBusy(false)
                message = error.localizedDescription
                // Reopen native handles for retry without losing the original.
                playerView.beginTrimming { [weak self] selection in
                    Task { @MainActor [weak self] in self?.handleTrim(selection) }
                }
            }
        }
    }
    func keepFull() { guard ready, !busy else { return }; finish(result.url) }
    func cancel() {
        if busy { task?.cancel(); return }
        finish(nil)
    }
    private func finish(_ url: URL?) {
        guard !closed else { return }
        closed = true
        task?.cancel()
        playerView.player?.pause()
        playerView.player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        onComplete(url)
    }
}

private struct RecordingReviewPlayer: NSViewRepresentable {
    let view: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { }
}

private struct RecordingReviewView: View {
    @Bindable var model: RecordingReviewModel
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            RecordingReviewPlayer(view: model.playerView)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!model.busy)
            if let message = model.message {
                Text(L10n.display(message)).foregroundStyle(AppTheme.Status.warningColor).font(.system(size: AppTheme.FontSize.sm))
            }
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("Trimming recording…"))
                } else {
                    Text(L10n.string("Trim the beginning and end before processing."))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                Spacer()
                Button(L10n.string("Keep full recording & continue")) { model.keepFull() }.disabled(!model.ready || model.busy)
                Button(L10n.string("Cancel")) { model.cancel() }.disabled(model.busy)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor)
    }
}
