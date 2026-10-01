import AppKit
import Observation
import SwiftUI
@preconcurrency import ScreenCaptureKit

/// App-owned picker so macOS 15.0 can preserve exact process identities on recovery.
@MainActor
@Observable
final class RecordingApplicationPicker: NSObject, NSWindowDelegate {
    static let shared = RecordingApplicationPicker()

    var displayID: UInt32 = 0
    var selectedProcessIDs: Set<Int32> = []
    var query = ""
    private(set) var displays: [RecordingApplicationDisplay] = []
    private(set) var candidates: [RecordingApplicationCandidate] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var panel: NSWindow?
    @ObservationIgnored private var continuation: CheckedContinuation<RecordingApplicationSelection, Error>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var preferredTarget: RecordingApplicationTarget?

    var visibleCandidates: [RecordingApplicationCandidate] {
        candidates.filter {
            $0.displayIDs.contains(displayID) && (query.isEmpty || $0.application.name.localizedCaseInsensitiveContains(query)
                || $0.application.bundleIdentifier.localizedCaseInsensitiveContains(query))
        }
    }

    var selection: RecordingApplicationSelection {
        RecordingApplicationSelection(displayID: displayID, applications: candidates.filter {
            selectedProcessIDs.contains($0.id) && $0.displayIDs.contains(displayID)
        }.map(\.application))
    }

    func pick(content: SCShareableContent, preferred: RecordingApplicationTarget? = nil) async throws -> RecordingApplicationSelection {
        cancelPending()
        let id = UUID()
        operationID = id
        preferredTarget = preferred
        selectedProcessIDs = []
        query = ""
        errorMessage = nil
        apply(content)
        let preferredDisplays = preferred.flatMap { target in candidates.first { $0.application.matches(target) }?.displayIDs }
        displayID = displays.first { preferredDisplays?.contains($0.id) == true }?.id
            ?? displays.first { $0.id == NSScreen.main?.displayID }?.id ?? displays.first?.id ?? 0
        selectPreferredTarget()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 490),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = L10n.string("Choose apps to record")
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                panel.delegate = self
                let hostingView = NSHostingView(rootView: RecordingApplicationPickerView(picker: self)
                    .appZoomEnvironment().appLocalization())
                // The window supplies the viewport; the app list must scroll rather
                // than grow the window to the hosting view's ideal content height.
                hostingView.sizingOptions = []
                panel.contentView = hostingView
                panel.setContentSize(NSSize(width: 660, height: 490))
                panel.contentMinSize = NSSize(width: 560, height: 400)
                self.panel = panel
                // Menus and dismissed sheets can leave a hidden key window. A standalone
                // panel also works when Meeting Recorder routes to a different main view.
                panel.center()
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                if Task.isCancelled { cancelPending() }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.operationID == id else { return }
                self.cancelPending()
            }
        }
    }

    func changeDisplay(_ id: UInt32) {
        displayID = id
        selectedProcessIDs = []
        selectPreferredTarget()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        let id = operationID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.isRefreshing = false; self.refreshTask = nil } }
            do {
                let content = try await RecordingPermission.shareableContent()
                try Task.checkCancellation()
                guard self.operationID == id, self.continuation != nil else { return }
                self.apply(content)
                if !self.displays.contains(where: { $0.id == self.displayID }) {
                    self.displayID = self.displays.first?.id ?? 0
                    self.selectedProcessIDs = []
                }
                self.selectedProcessIDs.formIntersection(Set(self.candidates.filter { $0.displayIDs.contains(self.displayID) }.map(\.id)))
            } catch is CancellationError {
                return
            } catch {
                guard self.operationID == id else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func confirm() {
        guard !isRefreshing, RecordingApplicationSelectionResolver.validate(selection, candidates: candidates) else { return }
        finish(.success(selection))
    }

    func cancelPending() { finish(.failure(RecordingError.cancelled)) }

    func windowWillClose(_ notification: Notification) { cancelPending() }

    private func apply(_ content: SCShareableContent) {
        displays = content.displays.map { RecordingApplicationDisplay(id: $0.displayID, frame: $0.frame) }
            .sorted { $0.id < $1.id }
        candidates = RecordingApplicationContent.candidates(in: content)
    }

    private func selectPreferredTarget() {
        if let preferredTarget,
           let candidate = candidates.first(where: { $0.application.matches(preferredTarget) && $0.displayIDs.contains(displayID) }) {
            selectedProcessIDs = [candidate.id]
        }
    }

    private func finish(_ result: Result<RecordingApplicationSelection, Error>) {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        let pending = continuation
        continuation = nil
        if let panel {
            panel.delegate = nil
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }
        pending?.resume(with: result)
    }
}

private struct RecordingApplicationPickerView: View {
    @Bindable var picker: RecordingApplicationPicker

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Choose apps to record"))
                .font(.system(size: AppTheme.FontSize.title2, weight: .semibold))
            Text(L10n.string("Capture selected apps on one display. Other apps and the desktop stay out of the recording."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(L10n.string("Display"), selection: Binding(get: { picker.displayID }, set: { picker.changeDisplay($0) })) {
                    ForEach(Array(picker.displays.enumerated()), id: \.element.id) { index, display in
                        Text(displayName(display.id, index: index)).tag(display.id)
                    }
                }
                TextField(L10n.string("Search apps"), text: $picker.query)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(picker.visibleCandidates) { candidate in
                        appRow(candidate.application)
                    }
                    if picker.visibleCandidates.isEmpty {
                        Text(L10n.string("No recordable apps on this display. Open an app window, then refresh."))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .padding(AppTheme.Spacing.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = picker.errorMessage {
                Text(L10n.display(message)).foregroundStyle(AppTheme.Status.errorColor)
                    .font(.system(size: AppTheme.FontSize.xs))
            }
            HStack {
                Button { picker.refresh() } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(picker.isRefreshing)
                if picker.isRefreshing { ProgressView().controlSize(.small) }
                Text(L10n.format("%d apps selected", picker.selection.applications.count))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Button(L10n.string("Cancel")) { picker.cancelPending() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("Start recording")) { picker.confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picker.selection.applications.isEmpty || picker.isRefreshing)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
    }

    private func appRow(_ app: RecordingApplicationTarget) -> some View {
        Toggle(isOn: Binding(get: { picker.selectedProcessIDs.contains(app.id) }, set: { selected in
            if selected { picker.selectedProcessIDs.insert(app.id) } else { picker.selectedProcessIDs.remove(app.id) }
        })) {
            HStack(spacing: AppTheme.Spacing.md) {
                if let icon = NSRunningApplication(processIdentifier: app.processID)?.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app").frame(width: 32, height: 32)
                }
                Text(app.name).fontWeight(.medium)
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .accessibilityIdentifier("recording-app-\(app.processID)")
    }

    private func displayName(_ id: UInt32, index: Int) -> String {
        NSScreen.screens.first { $0.displayID == id }?.localizedName ?? L10n.format("Display %d", index + 1)
    }
}
