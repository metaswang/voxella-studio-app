import AppKit
import SwiftUI

struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: AppTheme.FontSize.xl, weight: .regular)
        field.textColor = AppTheme.Text.primary
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.textColor = AppTheme.Text.primary

        let isFirstResponder = field.window.map { field.isFirstResponder(in: $0) } ?? false
        if field.stringValue != text, !isFirstResponder {
            field.stringValue = text
        }

        field.wantsFocus = isFocused
        guard let window = field.window else { return }
        if isFocused, !field.isFirstResponder(in: window) {
            window.makeFirstResponder(field)
        } else if !isFocused, field.isFirstResponder(in: window) {
            window.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SessionSearchField

        init(parent: SessionSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            (notification.object as? SearchTextField)?.refreshInsertionPoint()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            (field as? SearchTextField)?.refreshInsertionPoint()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.isFocused = true
            return true
        }
    }
}

final class SearchTextField: NSTextField {
    var wantsFocus = false {
        didSet {
            guard wantsFocus else { return }
            requestFocusIfNeeded()
        }
    }

    override func currentEditor() -> NSText? {
        let editor = super.currentEditor()
        configureInsertionPoint(in: editor)
        return editor
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            configureInsertionPoint(in: super.currentEditor())
        }
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocusIfNeeded()
    }

    func isFirstResponder(in window: NSWindow) -> Bool {
        window.firstResponder === self || window.firstResponder === currentEditor()
    }

    func refreshInsertionPoint() {
        configureInsertionPoint(in: currentEditor())
    }

    private func requestFocusIfNeeded() {
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, let window = self.window else { return }
            guard !self.isFirstResponder(in: window) else { return }
            window.makeFirstResponder(self)
        }
    }

    private func configureInsertionPoint(in editor: NSText?) {
        guard let textView = editor as? NSTextView else { return }
        textView.insertionPointColor = AppTheme.Text.primary
        textView.updateInsertionPointStateAndRestartTimer(true)
    }
}
