import AppKit
import SwiftUI

struct LocalModelManagerView: View {
    enum Presentation {
        case window
        case settings
    }

    var presentation: Presentation = .window

    @Bindable private var manager = LocalModelManager.shared
    @State private var removalCandidate: LocalModelDescriptor?
    @State private var licenseCandidate: LocalModelDescriptor?
    @State private var continueRecommendedDownload = false

    private var isEmbedded: Bool { presentation == .settings }

    var body: some View {
        Group {
            if isEmbedded {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        embeddedHeader
                        modelSections
                    }
                    .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, AppTheme.Spacing.xxl)
                    .padding(.top, AppTheme.Spacing.xxl)
                    .padding(.bottom, AppTheme.Spacing.xxl)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    windowHeader
                    Divider()
                    ScrollView {
                        modelSections
                            .padding(AppTheme.Spacing.xl)
                    }
                }
                .frame(width: 820, height: 680)
                .background(AppTheme.Background.baseColor)
            }
        }
        .alert("Remove local model?", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button("Cancel", role: .cancel) { removalCandidate = nil }
            Button("Remove", role: .destructive) {
                if let model = removalCandidate { manager.remove(model.id) }
                removalCandidate = nil
            }
        } message: {
            Text("This removes the cached model files from this Mac. They can be downloaded again later.")
        }
        .alert("Review model license", isPresented: Binding(
            get: { licenseCandidate != nil },
            set: { if !$0 { licenseCandidate = nil; continueRecommendedDownload = false } }
        )) {
            Button("Cancel", role: .cancel) {
                licenseCandidate = nil
                continueRecommendedDownload = false
            }
            if let url = licenseCandidate?.licenseURL {
                Button("Open License") { NSWorkspace.shared.open(url) }
            }
            Button("Accept & Download") {
                guard let model = licenseCandidate else { return }
                manager.acceptLicense(model.id)
                licenseCandidate = nil
                if continueRecommendedDownload {
                    continueRecommendedDownload = false
                    manager.downloadRecommended()
                } else {
                    manager.download(model.id)
                }
            }
        } message: {
            Text("This model is distributed under the \(licenseCandidate?.license ?? "model") license. Confirm that you have reviewed and accept it before its files are downloaded.")
        }
        .onAppear { manager.refreshInstallationStates() }
    }

    private var embeddedHeader: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Models")
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Downloads are the only network activity in the local edition, and start only when you click Download.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Button(recommendedComplete ? "Recommended Installed" : "Download Recommended") {
                beginRecommendedDownload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(recommendedBusy || recommendedComplete)
        }
    }

    private var windowHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Local Model Manager")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text("Downloads are the only network activity in the local edition, and start only when you click Download.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Button(recommendedComplete ? "Recommended Installed" : "Download Recommended") {
                beginRecommendedDownload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(recommendedBusy || recommendedComplete)
            Button("Done") { LocalModelManagerWindowController.shared.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(AppTheme.Spacing.xl)
    }

    @ViewBuilder
    private var modelSections: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            modelSection("Transcription & Captions", feature: .transcribe)
            modelSection("Dubbing", feature: .dub)
            if !manager.installedLegacyModels.isEmpty {
                modelSection("Legacy Models", models: manager.installedLegacyModels)
            }

            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .foregroundStyle(AppTheme.Status.successColor)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Offline after installation")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    Text("Inference loads cached files with offline mode enabled. Model licenses and repository identities are shown above.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(
                AppTheme.Status.successColor.opacity(AppTheme.Opacity.subtle),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            )
        }
    }

    private func modelSection(
        _ title: String,
        feature: LocalModelDescriptor.LocalFeature
    ) -> some View {
        modelSection(title, models: manager.models(for: feature))
    }

    private func modelSection(
        _ title: String,
        models: [LocalModelDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(models) { model in
                    modelRow(model)
                    if model.id != models.last?.id { Divider() }
                }
            }
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
            )
        }
    }

    private func modelRow(_ model: LocalModelDescriptor) -> some View {
        let state = manager.state(for: model.id)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon(for: model.id))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint(for: model.id))
                .frame(width: 38, height: 38)
                .background(tint(for: model.id).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(model.title)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    if manager.isActiveASRModel(model.id) {
                        Text("ACTIVE")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                            .tracking(AppTheme.Spacing.xxs)
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                    if model.isRecommended {
                        Text("RECOMMENDED")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                            .tracking(AppTheme.Spacing.xxs)
                            .foregroundStyle(AppTheme.Status.successColor)
                    } else if model.id == .whisperLargeV3TurboFP16 {
                        Text("MAX QUALITY")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                            .tracking(AppTheme.Spacing.xxs)
                            .foregroundStyle(AppTheme.Accent.timecodeColor)
                    }
                }
                Text(model.purpose)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text("\(model.repository) @ \(model.revision.prefix(8)) · \(model.license) · \(model.sizeLabel)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .textSelection(.enabled)
                if case .downloading(let progress, let message) = state {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(message)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .padding(.top, 4)
                }
                if case .failed(let message) = state {
                    Text(message)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            action(for: model, state: state)
        }
        .padding(14)
    }

    @ViewBuilder
    private func action(for model: LocalModelDescriptor, state: LocalModelDownloadState) -> some View {
        switch state {
        case .notInstalled, .failed:
            Button(downloadButtonTitle(for: model)) { beginDownload(model) }
                .buttonStyle(.bordered)
        case .queued:
            ProgressView().controlSize(.small)
            Button("Cancel") { manager.cancel(model.id) }
                .buttonStyle(.borderless)
        case .downloading:
            Button("Cancel") { manager.cancel(model.id) }
                .buttonStyle(.borderless)
        case .installed:
            VStack(alignment: .trailing, spacing: 5) {
                Label(
                    manager.isActiveASRModel(model.id) ? "Active" : "Installed",
                    systemImage: "checkmark.circle.fill"
                )
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.successColor)
                if model.id.isASRModel, !manager.isActiveASRModel(model.id) {
                    Button("Use") { manager.useASRModel(model.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                if !manager.isActiveASRModel(model.id) {
                    Button("Remove", role: .destructive) { removalCandidate = model }
                        .buttonStyle(.borderless)
                        .font(.system(size: AppTheme.FontSize.xs))
                }
            }
        }
    }

    private var recommendedBusy: Bool {
        LocalModelManager.catalog.contains { $0.isRecommended && manager.state(for: $0.id).isBusy }
    }

    private var recommendedComplete: Bool {
        LocalModelManager.catalog
            .filter(\.isRecommended)
            .allSatisfy { manager.state(for: $0.id).isInstalled }
    }

    private func beginDownload(_ model: LocalModelDescriptor) {
        if model.requiresLicenseAcceptance, !manager.isLicenseAccepted(model.id) {
            continueRecommendedDownload = false
            licenseCandidate = model
        } else {
            if model.id.isASRModel, !manager.isActiveASRModel(model.id) {
                manager.downloadAndUseASRModel(model.id)
            } else {
                manager.download(model.id)
            }
        }
    }

    private func downloadButtonTitle(for model: LocalModelDescriptor) -> String {
        model.id.isASRModel && !manager.isActiveASRModel(model.id) ? "Download & Use" : "Download"
    }

    private func beginRecommendedDownload() {
        if let model = LocalModelManager.catalog.first(where: {
            $0.isRecommended && $0.requiresLicenseAcceptance && !manager.isLicenseAccepted($0.id)
        }) {
            continueRecommendedDownload = true
            licenseCandidate = model
        } else {
            manager.downloadRecommended()
        }
    }

    private func icon(for id: LocalModelID) -> String {
        switch id {
        case .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16, .whisperSmall:
            "waveform.badge.magnifyingglass"
        case .spokenLanguageID: "character.bubble"
        case .forcedAligner: "text.line.first.and.arrowtriangle.forward"
        case .sileroVAD: "waveform.path.ecg"
        case .sortformerDiarization: "person.2.wave.2"
        case .pyannoteSegmentation: "person.2.wave.2"
        case .weSpeaker: "person.crop.circle.badge.checkmark"
        case .qwenTTS06B, .qwenTTS17B: "speaker.wave.3"
        }
    }

    private func tint(for id: LocalModelID) -> Color {
        switch id {
        case .qwenTTS06B, .qwenTTS17B: .purple
        case .sortformerDiarization, .pyannoteSegmentation, .weSpeaker: .orange
        default: .blue
        }
    }
}

@MainActor
final class LocalModelManagerWindowController: NSWindowController {
    static let shared = LocalModelManagerWindowController()

    private init() {
        let content = LocalModelManagerView().tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 820, height: 680))
        window.minSize = NSSize(width: 760, height: 580)
        window.title = "Local Models"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
