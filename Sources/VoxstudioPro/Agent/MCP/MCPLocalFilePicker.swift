import AppKit
import UniformTypeIdentifiers

/// One native picker across MCP connections; never stack hidden modal windows.
@MainActor
final class MCPLocalFilePicker {
    static let shared = MCPLocalFilePicker()
    private var panel: NSOpenPanel?

    func choose(media: Bool) async throws -> URL? {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            throw MCPDocumentError("picker_busy", "A VoxStudio file picker is already open. Select a file or cancel it before opening another.")
        }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = media ? [.audio, .movie] : MCPDocumentCodec.extensions.compactMap { UTType(filenameExtension: $0) }
        picker.title = media ? "Choose audio or video — VoxStudio" : "Choose a document — VoxStudio"
        picker.message = media ? "Select media for the transcription panel. Choosing a file does not start transcription." : "Select a UTF-8 document to import into VoxStudio."
        panel = picker
        defer { panel = nil }
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            picker.begin { continuation.resume(returning: $0) }
            picker.makeKeyAndOrderFront(nil)
        }
        return response == .OK ? picker.url : nil
    }
}
