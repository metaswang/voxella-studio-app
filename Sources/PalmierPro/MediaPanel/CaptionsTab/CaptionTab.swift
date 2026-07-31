import SwiftUI

struct CaptionTab: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var models = LocalModelManager.shared

    @State private var style: TextStyle = CaptionTab.defaultStyle
    @State private var center = AppTheme.Caption.defaultCenter

    private static var defaultStyle: TextStyle {
        var s = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        s.shadow.enabled = false
        return s
    }
    @State private var selectedTrackId: String?
    @State private var selectedClipTargets: [String] = []
    private let provider: TranscriptionProvider = .local
    @State private var animationPreset: TextAnimation.Preset = .none
    @State private var animationHighlight: TextStyle.RGBA = TextAnimation.defaultHighlight
    @State private var maxWords: Int?
    @State private var locale: Locale?
    @State private var supportedLocales: [Locale] = []
    @State private var isGenerating = false
    @State private var note: String?
    @State private var sourceExpanded = true
    @State private var settingsExpanded = true
    @State private var styleExpanded = false
    @State private var animationExpanded = false
    @State private var placementExpanded = true

    private static let previewText = "Captions will look like this"

    private var aspect: CGFloat { CGFloat(editor.timeline.width) / CGFloat(max(1, editor.timeline.height)) }

    private var liveTargets: [String] {
        let sel = editor.selectedClipIds
        guard !sel.isEmpty else { return [] }
        return editor.captionTargets(ids: Array(sel)).map(\.id)
    }
    private var isAutoSource: Bool { selectedTrackId == nil && selectedClipTargets.isEmpty }
    private var sourceClipIds: [String] {
        if let selectedTrackId { return editor.captionTargets(trackIds: [selectedTrackId]).map(\.id) }
        return selectedClipTargets   // Auto resolves its source during generation
    }
    private var automaticSourceSummary: String {
        if !selectedClipTargets.isEmpty { return "Selected Clips · \(selectedClipTargets.count)" }
        return editor.captionTargets(ids: []).isEmpty ? "No audio" : "Auto"
    }
    private var effectiveCount: Int {
        isAutoSource ? editor.captionTargets(ids: []).count : sourceClipIds.count
    }
    private var captionTrackIndices: [Int] {
        editor.timeline.tracks.indices.filter { !editor.captionTargets(trackIds: [editor.timeline.tracks[$0].id]).isEmpty }
    }
    private var canGenerateCaptions: Bool {
        effectiveCount > 0 && !isGenerating
    }

    private var sourceSummary: String {
        guard let selectedTrackId else { return automaticSourceSummary }
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == selectedTrackId }) else { return "No track" }
        return "\(trackTitle(index)) · \(sourceClipIds.count)"
    }

    var body: some View {
        ZStack {
            VStack(spacing: AppTheme.Spacing.zero) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        sourceSection
                        settingsSection
                        styleSection
                        animationSection
                        placementSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: "Transcribing…", size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = (await Transcription.supportedLocales())
                .sorted { languageName($0) < languageName($1) }
        }
        .onAppear { rememberSelectedClipTargets() }
        .onChange(of: editor.selectedClipIds) { _, _ in
            guard !editor.isMarqueeSelecting else { return }
            rememberSelectedClipTargets()
        }
        .onChange(of: editor.isMarqueeSelecting) { wasSelecting, isSelecting in
            guard wasSelecting, !isSelecting else { return }
            rememberSelectedClipTargets()
        }
    }

    private var sourceSection: some View {
        EditorPanelGroup("Source", isExpanded: $sourceExpanded) {
            InspectorRow(
                label: "Source",
                labelHelp: "Uses selected clips when available, otherwise all captionable audio. Choose a track to limit captions.",
                onReset: {
                    selectedTrackId = nil
                    selectedClipTargets = []
                }
            ) { sourceMenu }
            InspectorRow(label: "Mode") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(AppTheme.Status.successColor)
                    Text("Local MLX")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer()
                }
            }
        }
    }

    private var settingsSection: some View {
        EditorPanelGroup("Settings", isExpanded: $settingsExpanded) {
            InspectorRow(label: "Language", onReset: { locale = nil }) {
                Menu {
                    Button("Auto") { locale = nil }
                    if !supportedLocales.isEmpty {
                        Divider()
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button(languageName(loc)) { locale = loc }
                        }
                    }
                } label: { EditorMenuValue(text: locale.map(languageName) ?? "Auto", expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
            InspectorRow(
                label: "Max words",
                labelHelp: "Cap the words shown per caption. None fits each line to the box.",
                onReset: { maxWords = nil }
            ) {
                Menu {
                    Button("None") { maxWords = nil }
                    ForEach(1...8, id: \.self) { n in
                        Button("\(n)") { maxWords = n }
                    }
                } label: { EditorMenuValue(text: maxWords.map(String.init) ?? "None", expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                selectedTrackId = nil
            } label: {
                Label(automaticSourceSummary, systemImage: selectedTrackId == nil ? "checkmark" : "")
            }

            Divider()

            if captionTrackIndices.isEmpty {
                Text("No Tracks")
            } else {
                ForEach(captionTrackIndices, id: \.self) { index in
                    if editor.timeline.tracks.indices.contains(index) {
                        let track = editor.timeline.tracks[index]
                        let count = editor.captionTargets(trackIds: [track.id]).count
                        Button {
                            selectedTrackId = track.id
                        } label: {
                            Label(
                                "\(trackTitle(index)) · \(count) \(count == 1 ? "clip" : "clips")",
                                systemImage: selectedTrackId == track.id ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
        } label: {
            EditorMenuValue(text: sourceSummary, expanded: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .frame(maxWidth: .infinity)
    }

    private func rememberSelectedClipTargets() {
        let targets = liveTargets
        guard !targets.isEmpty || editor.focusedPanel != .media else { return }
        selectedClipTargets = targets
    }

    private func trackTitle(_ index: Int) -> String {
        editor.timelineTrackDisplayLabel(at: index)
    }

    private func languageName(_ loc: Locale) -> String {
        Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier(.bcp47)
    }

    private var styleSection: some View {
        TextStyleControls(
            selection: TextStyleSelection(styles: [style], fallback: Self.defaultStyle),
            defaults: Self.defaultStyle,
            styleExpanded: $styleExpanded,
            groupsExpandedByDefault: false,
            actions: styleActions
        )
    }

    private var styleActions: TextStyleEditingActions {
        TextStyleEditingActions(
            apply: { _, mutation in mutation(&style) },
            commit: { _, mutation in mutation(&style) },
            commitColor: { _, mutation in mutation(&style) },
            cancelPending: { _ in },
            cancelFontPreview: { originalFont in
                if let originalFont { style.fontName = originalFont }
            }
        )
    }

    private var animationSection: some View {
        EditorPanelGroup("Animation", isExpanded: $animationExpanded) {
            CaptionPresetGallery(selection: $animationPreset, highlight: animationHighlight)
            if animationPreset.usesHighlight {
                InspectorRow(
                    label: "Highlight",
                    labelHelp: "Color for the active word.",
                    onReset: { animationHighlight = TextAnimation.defaultHighlight }
                ) {
                    ColorField(displayColor: animationHighlight.swiftUIColor, onUserChange: { animationHighlight = TextStyle.RGBA($0) })
                }
            }
        }
    }

    private var placementSection: some View {
        EditorPanelGroup("Placement", isExpanded: $placementExpanded) {
            previewBox
            HStack(spacing: AppTheme.Spacing.mdLg) {
                Spacer(minLength: AppTheme.Spacing.xs)
                posField("X", value: center.x) { center.x = $0 }
                posField("Y", value: center.y) { center.y = $0 }
            }
        }
    }

    private var previewBox: some View {
        ZStack {
            AppTheme.Background.previewCanvasColor
            centerGuides
            GeometryReader { geo in
                CaptionAnimatedPreview(
                    text: Self.previewText, style: style, center: center,
                    preset: animationPreset, highlight: animationHighlight,
                    canvas: CGSize(width: max(1, editor.timeline.width), height: max(1, editor.timeline.height)),
                    size: geo.size
                )
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: AppTheme.ComponentSize.captionPreviewMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var centerGuides: some View {
        GeometryReader { geo in
            let guide = AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.prominent)
            ZStack {
                if center.x == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: AppTheme.BorderWidth.hairline, height: geo.size.height)
                }
                if center.y == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: geo.size.width, height: AppTheme.BorderWidth.hairline)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func snapCenter(_ v: Double) -> CGFloat {
        let centerValue = Double(AppTheme.Caption.centerSnapValue)
        return CGFloat(abs(v - centerValue) < AppTheme.Caption.centerSnapThreshold ? centerValue : v)
    }

    private func posField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ScrubbableNumberField(
                value: Double(value),
                range: AppTheme.Caption.minPosition...AppTheme.Caption.maxPosition,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                onChanged: { onChange(snapCenter($0)) }
            ) { onChange(snapCenter($0)) }
        }
    }

    private var generateBar: some View {
        EditorActionFooter(message: note) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if models.hasRequiredModels(for: .transcribe) {
                    Button(action: generate) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text("Generate Local Captions")
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.editorPrimary)
                    .focusable(false)
                    .disabled(!canGenerateCaptions)
                } else {
                    Button("Download Local Models…") { models.presentManager() }
                        .buttonStyle(.editorPrimary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func generate() {
        note = nil
        let sourceIds = sourceClipIds
        if selectedTrackId != nil && sourceIds.isEmpty {
            note = "No audio selected."
            return
        }
        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: sourceIds,
            autoDetect: isAutoSource,
            style: style,
            center: center,
            censorProfanity: false,
            locale: locale,
            maxWords: maxWords,
            provider: provider,
            animation: TextAnimation(preset: animationPreset, highlight: animationHighlight)
        )
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                if try await editor.generateCaptions(for: request).isEmpty { note = "No speech detected." }
            } catch {
                note = error.localizedDescription
            }
        }
    }

}
