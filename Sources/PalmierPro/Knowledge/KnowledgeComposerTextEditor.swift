import AppKit
import SwiftUI

/// Growing, wrapping chat composer backed by `NSTextView`.
///
/// - Return sends (when not composing IME marked text)
/// - Shift+Return inserts a newline
/// - While Chinese/pinyin (or any IME) has marked text, Return only commits composition
struct KnowledgeComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    var fontSize: CGFloat = AppTheme.FontSize.md
    var minLines: Int = 1
    var maxLines: Int = 8
    var onSubmit: () -> Void

    private var textInset: NSSize {
        NSSize(width: 0, height: 2)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let editor = ComposerTextView()
        editor.minSize = .zero
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = textInset
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = NSColor(AppTheme.Text.primaryColor)
        editor.insertionPointColor = NSColor(AppTheme.Text.primaryColor)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.focusRingType = .none

        scroll.documentView = editor
        scroll.onWidthChange = { [weak coordinator = context.coordinator, weak scroll] in
            guard let coordinator, let scroll, let editor = scroll.documentView as? NSTextView else { return }
            coordinator.recalculateHeight(editor: editor, scroll: scroll, force: false)
        }

        context.coordinator.recalculateHeight(editor: editor, scroll: scroll, force: true)
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }

        scroll.onWidthChange = { [weak coordinator = context.coordinator, weak scroll] in
            guard let coordinator, let scroll, let editor = scroll.documentView as? NSTextView else { return }
            coordinator.recalculateHeight(editor: editor, scroll: scroll, force: false)
        }

        if editor.string != text {
            let selected = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            let maxLen = max(0, length - location)
            editor.setSelectedRange(NSRange(location: location, length: min(selected.length, maxLen)))
            editor.undoManager?.removeAllActions(withTarget: editor)
        }

        editor.placeholder = placeholder
        editor.isEditable = context.environment.isEnabled
        editor.isSelectable = true
        editor.needsDisplay = true
        context.coordinator.recalculateHeight(editor: editor, scroll: scroll, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KnowledgeComposerTextEditor

        init(parent: KnowledgeComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
            if let scroll = editor.enclosingScrollView {
                recalculateHeight(editor: editor, scroll: scroll, force: true)
            }
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            else {
                return false
            }

            // IME composing (e.g. Chinese pinyin): Return commits marked text only.
            if textView.hasMarkedText() {
                return false
            }

            let shiftHeld = NSApp.currentEvent?
                .modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift) == true
            if shiftHeld {
                // Shift+Return → newline (do not submit).
                return false
            }

            parent.onSubmit()
            return true
        }

        func recalculateHeight(editor: NSTextView, scroll: NSScrollView, force: Bool) {
            guard let layoutManager = editor.layoutManager,
                  let textContainer = editor.textContainer,
                  let font = editor.font
            else { return }

            let width = max(scroll.bounds.width, 1)
            if abs(textContainer.containerSize.width - width) > 0.5 {
                textContainer.containerSize = NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
                editor.frame.size.width = width
            }

            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let inset = editor.textContainerInset
            let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
            let minHeight = CGFloat(parent.minLines) * lineHeight + inset.height * 2
            let maxHeight = CGFloat(parent.maxLines) * lineHeight + inset.height * 2
            let contentHeight = ceil(used.height + inset.height * 2)
            let next = min(maxHeight, max(minHeight, max(contentHeight, lineHeight + inset.height * 2)))

            let needsScroll = contentHeight > maxHeight + 0.5
            if scroll.hasVerticalScroller != needsScroll {
                scroll.hasVerticalScroller = needsScroll
            }

            if force || abs(parent.height - next) > 0.5 {
                parent.height = next
            }
        }
    }
}

@MainActor
final class ComposerScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = bounds.width
        if abs(width - lastWidth) > 0.5 {
            lastWidth = width
            onWidthChange?()
        }
    }
}

@MainActor
private final class ComposerTextView: NSTextView {
    var placeholder = ""

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textContainerInset
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(used.height + inset.height * 2)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let textContainer, let font else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: NSColor(AppTheme.Text.mutedColor)
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: textContainer.containerSize)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}
