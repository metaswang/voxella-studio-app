import AppKit
import SwiftUI

/// Native editor measurements never write back into SwiftUI state.
struct KnowledgeComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = AppTheme.FontSize.md
    var minLines: Int = 1
    var maxLines: Int = 5
    var onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
            ?? (nsView.bounds.width > 1 ? nsView.bounds.width : 240)
        return CGSize(width: width, height: context.coordinator.measure(width: width))
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let editor = ComposerTextView()
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: KnowledgeComposerMetrics.verticalInset)
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = NSColor(AppTheme.Text.primaryColor)
        editor.insertionPointColor = NSColor(AppTheme.Text.primaryColor)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.focusRingType = .none
        editor.string = text
        editor.placeholder = placeholder
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        // Redraws and voice updates must preserve an IME's marked text.
        if !editor.hasMarkedText(), editor.string != text {
            coordinator.isUpdating = true
            let selected = editor.selectedRange()
            editor.string = text
            let length = text.utf16.count
            let location = min(selected.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
            editor.undoManager?.removeAllActions()
            coordinator.isUpdating = false
        }
        let font = NSFont.systemFont(ofSize: fontSize)
        if editor.font != font { editor.font = font }
        editor.placeholder = placeholder
        editor.isEditable = context.environment.isEnabled
        editor.isSelectable = true
        editor.needsDisplay = true
        scroll.needsLayout = true
    }

    static func dismantleNSView(_ nsView: ComposerScrollView, coordinator: Coordinator) {
        coordinator.isActive = false
        (nsView.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KnowledgeComposerTextEditor
        var isUpdating = false
        var isActive = true
        private var submissionPending = false
        private var measuredInput: MeasurementInput?
        private var measuredHeight: CGFloat = 0
        private struct MeasurementInput: Equatable {
            let text: String
            let width: CGFloat
            let fontSize: CGFloat
            let minLines: Int
            let maxLines: Int
        }
        init(parent: KnowledgeComposerTextEditor) { self.parent = parent }

        func measure(width: CGFloat) -> CGFloat {
            let input = MeasurementInput(text: parent.text, width: width, fontSize: parent.fontSize,
                                         minLines: parent.minLines, maxLines: parent.maxLines)
            if input != measuredInput {
                measuredHeight = KnowledgeComposerMetrics.height(text: input.text, width: width,
                    fontSize: input.fontSize, minLines: input.minLines, maxLines: input.maxLines)
                measuredInput = input
            }
            return measuredHeight
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            else { return false }
            let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            guard Self.shouldSubmit(hasMarkedText: textView.hasMarkedText(), shiftHeld: shiftHeld) else { return false }
            submit(textView.string)
            return true
        }

        static func shouldSubmit(hasMarkedText: Bool, shiftHeld: Bool) -> Bool { !hasMarkedText && !shiftHeld }

        func submit(_ snapshot: String) {
            guard isActive, !submissionPending else { return }
            submissionPending = true
            // Finish the native Return event before clearing the editor or inserting rows.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.submissionPending = false
                guard self.isActive else { return }
                self.parent.onSubmit(snapshot)
            }
        }
    }
}

@MainActor
enum KnowledgeComposerMetrics {
    static let verticalInset: CGFloat = 2
    static func height(text: String, width: CGFloat, fontSize: CGFloat,
                       minLines: Int = 1, maxLines: Int = 5) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let minimum = CGFloat(max(1, minLines)) * lineHeight + verticalInset * 2
        let maximum = CGFloat(max(max(1, minLines), maxLines)) * lineHeight + verticalInset * 2
        guard width.isFinite, width > 1 else { return minimum }
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let content = manager.extraLineFragmentTextContainer === container
            ? max(used.maxY, manager.extraLineFragmentRect.maxY) : used.maxY
        return min(maximum, max(minimum, ceil(content + verticalInset * 2)))
    }
}

@MainActor
final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView, let container = editor.textContainer,
              contentSize.width > 1 else { return }
        let width = contentSize.width
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            editor.frame.size.width = width
        }
    }
}

@MainActor
private final class ComposerTextView: NSTextView {
    var placeholder = ""
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font else { return }
        (placeholder as NSString).draw(in: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y,
            width: max(0, bounds.width), height: bounds.height),
            withAttributes: [.font: font, .foregroundColor: NSColor(AppTheme.Text.mutedColor)])
    }
}
