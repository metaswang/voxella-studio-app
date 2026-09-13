import AppKit
import SwiftUI

struct NativePlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize = AppTheme.FontSize.md
    var textInset = NSSize(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
    var showsVerticalScroller = true
    var autofocus = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = PlaceholderTextView()
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
        editor.textContainerInset = textInset
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = NSColor(AppTheme.Text.primaryColor)
        editor.insertionPointColor = NSColor(AppTheme.Text.primaryColor)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.allowsUndo = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = showsVerticalScroller
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PlaceholderTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions(withTarget: editor)
        }
        editor.placeholder = placeholder
        editor.isEditable = context.environment.isEnabled
        editor.needsDisplay = true
        if autofocus, scroll.window?.firstResponder !== editor {
            DispatchQueue.main.async { scroll.window?.makeFirstResponder(editor) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePlaceholderTextEditor
        init(parent: NativePlaceholderTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let textContainer, let font else { return }
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
