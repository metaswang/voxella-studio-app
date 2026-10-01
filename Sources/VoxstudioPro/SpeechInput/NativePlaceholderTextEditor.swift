import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
protocol VoiceInputFocusTarget: AnyObject {
    func requestFocus()
}

struct NativePlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize = AppTheme.FontSize.md
    var textInset = NSSize(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
    var showsVerticalScroller = true
    var onReturn: (() -> Bool)? = nil
    var onEscape: (() -> Void)? = nil

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
        let coordinator = context.coordinator
        editor.onReturn = { [weak coordinator] in
            coordinator?.handleReturn() ?? false
        }
        editor.onEscape = { [weak coordinator] in
            coordinator?.handleEscape()
        }
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
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePlaceholderTextEditor
        init(parent: NativePlaceholderTextEditor) { self.parent = parent }

        func handleReturn() -> Bool {
            parent.onReturn?() ?? false
        }

        func handleEscape() {
            parent.onEscape?()
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}

@MainActor
private final class PlaceholderTextView: NSTextView, VoiceInputFocusTarget {
    var placeholder = ""
    var onReturn: (() -> Bool)?
    var onEscape: (() -> Void)?

    private var wantsFocus = false
    private var focusRequestScheduled = false

    override var needsPanelToBecomeKey: Bool { true }

    func requestFocus() {
        wantsFocus = true
        requestFocusIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocusIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)

        if isReturn, !modifiers.contains(.shift), onReturn?() == true {
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }

        super.keyDown(with: event)
    }

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

    private func requestFocusIfNeeded() {
        guard wantsFocus,
              let window,
              window.isKeyWindow,
              window.firstResponder !== self,
              !focusRequestScheduled else { return }

        focusRequestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusRequestScheduled = false
            guard wantsFocus,
                  let currentWindow = self.window,
                  currentWindow.isKeyWindow,
                  currentWindow.firstResponder !== self else { return }
            _ = currentWindow.makeFirstResponder(self)
        }
    }
}
