import AppKit
import SwiftUI
import Testing
@testable import VoxstudioPro

@Suite("Session cue layout", .serialized)
@MainActor
struct SessionCueLayoutTests {
    private let longText = String(
        repeating: "Last week, everything about AI changed forever, almost every week. ",
        count: 12
    )

    @Test func longEditorReservesItsFullHeightOnFirstLayout() throws {
        let (window, controller) = makeHost(text: longText, width: 600)
        defer { window.close() }

        let cardHeight = measuredHeight(of: controller, width: 600)
        let display = NSHostingController(rootView: makeRow(text: longText, isEditing: false))
        let displayHeight = measuredHeight(of: display, width: 600)
        #expect(cardHeight > AppTheme.Workbench.transcriptCardMinHeight * 2)
        // The old outer frame reserved one line while the native editor drew
        // all its lines beyond the card and over the following segment.
        #expect(cardHeight >= displayHeight - AppTheme.FontSize.mdLg)
    }

    @Test func editorRewrapsWhenColumnNarrowsAndWidens() throws {
        let (window, controller) = makeHost(text: longText, width: 800)
        defer { window.close() }
        let wideHeight = measuredHeight(of: controller, width: 800)

        window.setContentSize(NSSize(width: 400, height: 800))
        controller.view.layoutSubtreeIfNeeded()
        let narrowHeight = measuredHeight(of: controller, width: 400)
        #expect(narrowHeight > wideHeight)

        window.setContentSize(NSSize(width: 800, height: 800))
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(measuredHeight(of: controller, width: 800) - wideHeight) <= 1)
        let editor = try #require(findEditor(in: controller.view))
        let textView = try #require(editor.documentView as? NSTextView)
        #expect(abs(textView.frame.width - editor.contentSize.width) <= 1)
    }

    @Test func editorGrowsAndShrinksWithTextAndIncludesTrailingEmptyLine() {
        let (window, controller) = makeHost(text: "Hello", width: 500)
        defer { window.close() }
        let shortHeight = measuredHeight(of: controller, width: 500)

        controller.rootView = makeRow(text: longText)
        let longHeight = measuredHeight(of: controller, width: 500)
        #expect(longHeight > shortHeight)

        controller.rootView = makeRow(text: "Hello\n\n\n\n")
        let newlineHeight = measuredHeight(of: controller, width: 500)
        controller.rootView = makeRow(text: "Hello\n\n\n")
        #expect(newlineHeight > measuredHeight(of: controller, width: 500))

        controller.rootView = makeRow(text: "Hello")
        #expect(abs(measuredHeight(of: controller, width: 500) - shortHeight) <= 1)
    }

    private func measuredHeight(of controller: NSHostingController<SessionCueRow>, width: CGFloat) -> CGFloat {
        controller.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private func makeHost(text: String, width: CGFloat) -> (NSWindow, NSHostingController<SessionCueRow>) {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: makeRow(text: text))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Hidden test windows do not get the normal initial display pass.
        controller.view.frame = window.contentLayoutRect
        return (window, controller)
    }

    private func makeRow(text: String, isEditing: Bool = true) -> SessionCueRow {
        SessionCueRow(
            cue: SubtitleCue(id: 1, sourceIDs: [1], text: text, start: 0, end: 27.3, speaker: "Speaker 1"),
            isActive: false,
            speakerLabels: ["Speaker 1"],
            isEditing: isEditing,
            editingText: .constant(text),
            cursorOffset: .constant(nil),
            canSplit: false,
            onPlay: {},
            onBeginEdit: {},
            onCommitEdit: {},
            onCancelEdit: {},
            onSplit: {},
            onSelectSpeaker: { _ in },
            onRenameSpeaker: { _ in },
            onAddSpeaker: {}
        )
    }

    private func findEditor(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTextView {
            return scrollView
        }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }
}
