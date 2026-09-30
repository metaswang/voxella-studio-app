import AppKit

/// Builds the application main menu with keyboard shortcuts.
/// Called from AppDelegate to wire shortcuts into the responder chain.
@MainActor
enum MainMenuBuilder {
    private static let fileMenuIdentifier = NSUserInterfaceItemIdentifier("PalmierPro.mainMenu.file")
    private static let editMenuIdentifier = NSUserInterfaceItemIdentifier("PalmierPro.mainMenu.edit")

    static func buildMenu(editorMenusVisible: Bool = AppState.shared.isEditorActive) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        let fileMenu = fileMenu()
        fileMenu.isHidden = !editorMenusVisible
        mainMenu.addItem(fileMenu)
        let editMenu = editMenu()
        editMenu.isHidden = !editorMenusVisible
        mainMenu.addItem(editMenu)
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(helpMenu())
        return mainMenu
    }

    static func setEditorMenusVisible(_ visible: Bool, in mainMenu: NSMenu? = NSApp.mainMenu) {
        let editorMenuIdentifiers = [fileMenuIdentifier, editMenuIdentifier]
        for item in mainMenu?.items ?? [] where editorMenuIdentifiers.contains(where: { $0 == item.identifier }) {
            item.isHidden = !visible
        }
    }

    // MARK: - App menu

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: AppIdentity.productName)
        menu.addItem(
            withTitle: L10n.format("About %@", AppIdentity.productName),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
#if !MAC_APP_STORE
        menu.addItem(.separator())
        let updatesItem = menu.addItem(
            withTitle: L10n.string("Check for Updates…"),
            action: #selector(AppUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = AppUpdater.shared
#endif
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
#if !MAC_APP_STORE
        menu.addItem(withTitle: L10n.string("Activate License…"), action: #selector(AppDelegate.showActivateLicense(_:)), keyEquivalent: "")
#endif
        menu.addItem(withTitle: L10n.string("Local Features…"), action: #selector(AppDelegate.showLocalModels(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.format("Quit %@", AppIdentity.productName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = fileMenuIdentifier
        let menu = NSMenu(title: L10n.string("File"))
        let newItem = menu.addItem(withTitle: L10n.string("New"), action: #selector(AppDelegate.newProject(_:)), keyEquivalent: "n")
        newItem.target = NSApp.delegate
        let newFolderItem = NSMenuItem(title: L10n.string("New Folder"), action: #selector(EditorActions.newMediaFolder(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(newFolderItem)
        let openItem = menu.addItem(withTitle: L10n.string("Open…"), action: #selector(AppDelegate.openProject(_:)), keyEquivalent: "o")
        openItem.target = NSApp.delegate
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: L10n.string("Save As…"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        menu.addItem(.separator())

        let importItem = NSMenuItem(title: L10n.string("Import Media…"), action: #selector(EditorActions.importMedia(_:)), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command]
        menu.addItem(importItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: L10n.string("Export…"), action: #selector(EditorActions.showExport(_:)), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command]
        menu.addItem(exportItem)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = editMenuIdentifier
        let menu = NSMenu(title: L10n.string("Edit"))
        // Use editor-specific selectors so Cmd+Z reaches EditorUndo (not an empty
        // first-responder UndoManager / disabled AppKit undo:). Text fields still
        // get field-editor undo via EditorSessionController when focused.
        menu.addItem(withTitle: L10n.string("Undo"), action: #selector(EditorActions.undoEditor(_:)), keyEquivalent: "z")
        menu.addItem(withTitle: L10n.string("Redo"), action: #selector(EditorActions.redoEditor(_:)), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let selectForwardTrackItem = NSMenuItem(title: L10n.string("Select Forward on Track"), action: #selector(EditorActions.selectForwardOnTrack(_:)), keyEquivalent: "a")
        selectForwardTrackItem.keyEquivalentModifierMask = []
        menu.addItem(selectForwardTrackItem)

        let selectForwardAllItem = NSMenuItem(title: L10n.string("Select Forward on All Tracks"), action: #selector(EditorActions.selectForwardOnAllTracks(_:)), keyEquivalent: "a")
        selectForwardAllItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(selectForwardAllItem)

        menu.addItem(.separator())

        let splitItem = NSMenuItem(title: L10n.string("Split at Playhead"), action: #selector(EditorActions.splitAtPlayhead(_:)), keyEquivalent: "k")
        splitItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitItem)

        let trimStartItem = NSMenuItem(title: L10n.string("Trim Start to Playhead"), action: #selector(EditorActions.trimStartToPlayhead(_:)), keyEquivalent: "q")
        trimStartItem.keyEquivalentModifierMask = []
        menu.addItem(trimStartItem)

        let trimEndItem = NSMenuItem(title: L10n.string("Trim End to Playhead"), action: #selector(EditorActions.trimEndToPlayhead(_:)), keyEquivalent: "w")
        trimEndItem.keyEquivalentModifierMask = []
        menu.addItem(trimEndItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: L10n.string("Delete"), action: #selector(EditorActions.deleteSelectedClips(_:)), keyEquivalent: "\u{8}") // backspace
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        let rippleDeleteItem = NSMenuItem(title: L10n.string("Ripple Delete"), action: #selector(EditorActions.rippleDeleteSelected(_:)), keyEquivalent: "\u{8}") // backspace
        rippleDeleteItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(rippleDeleteItem)

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("View"))

        let increaseZoomItem = NSMenuItem(
            title: L10n.string("Zoom In"),
            action: #selector(AppDelegate.zoomIn(_:)),
            keyEquivalent: "+"
        )
        increaseZoomItem.keyEquivalentModifierMask = [.command, .shift]
        increaseZoomItem.target = NSApp.delegate
        menu.addItem(increaseZoomItem)

        let decreaseZoomItem = NSMenuItem(
            title: L10n.string("Zoom Out"),
            action: #selector(AppDelegate.zoomOut(_:)),
            keyEquivalent: "-"
        )
        decreaseZoomItem.keyEquivalentModifierMask = [.command]
        decreaseZoomItem.target = NSApp.delegate
        menu.addItem(decreaseZoomItem)

        let resetZoomItem = NSMenuItem(
            title: L10n.string("Reset Zoom"),
            action: #selector(AppDelegate.resetZoom(_:)),
            keyEquivalent: "0"
        )
        resetZoomItem.keyEquivalentModifierMask = [.command, .shift]
        resetZoomItem.target = NSApp.delegate
        menu.addItem(resetZoomItem)
        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: L10n.string("Search Sessions…"),
            action: #selector(AppDelegate.showSessionSearch(_:)),
            keyEquivalent: "k"
        )
        searchItem.keyEquivalentModifierMask = [.command]
        searchItem.target = NSApp.delegate
        menu.addItem(searchItem)
        menu.addItem(.separator())

        let mediaItem = NSMenuItem(title: L10n.string("Media Panel"), action: #selector(EditorActions.toggleMediaPanel(_:)), keyEquivalent: "0")
        mediaItem.keyEquivalentModifierMask = [.command]
        menu.addItem(mediaItem)

        let inspectorItem = NSMenuItem(title: L10n.string("Inspector"), action: #selector(EditorActions.toggleInspectorPanel(_:)), keyEquivalent: "0")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(inspectorItem)

        let agentItem = NSMenuItem(
            title: L10n.string("AI Editing Chat"),
            action: #selector(EditorActions.toggleAgentPanel(_:)),
            keyEquivalent: "a"
        )
        agentItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(agentItem)

        menu.addItem(.separator())

        let maximizeItem = NSMenuItem(title: L10n.string("Maximize Focused Panel"), action: #selector(EditorActions.toggleMaximizePanel(_:)), keyEquivalent: "`")
        maximizeItem.keyEquivalentModifierMask = []
        menu.addItem(maximizeItem)

        menu.addItem(.separator())
        menu.addItem(layoutSubmenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.submenu = menu
        return item
    }

    private static func layoutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("Layout"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.string("Layout"))

        let defaultItem = NSMenuItem(title: L10n.string(key: LayoutPreset.default.label), action: #selector(EditorActions.setLayoutDefault(_:)), keyEquivalent: "1")
        defaultItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(defaultItem)

        let mediaItem = NSMenuItem(title: L10n.string(key: LayoutPreset.media.label), action: #selector(EditorActions.setLayoutMedia(_:)), keyEquivalent: "2")
        mediaItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(mediaItem)

        let verticalItem = NSMenuItem(title: L10n.string(key: LayoutPreset.vertical.label), action: #selector(EditorActions.setLayoutVertical(_:)), keyEquivalent: "3")
        verticalItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(verticalItem)

        item.submenu = submenu
        return item
    }

    // MARK: - Help menu

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("Help"))
        menu.addItem(withTitle: L10n.string("Keyboard Shortcuts"), action: #selector(AppDelegate.showKeyboardShortcuts(_:)), keyEquivalent: "?")
        menu.addItem(withTitle: L10n.string("Local Features"), action: #selector(AppDelegate.showLocalModels(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Actions dispatched through the responder chain to reach the active EditorViewModel.
@MainActor @objc protocol EditorActions {
    func undoEditor(_ sender: Any?)
    func redoEditor(_ sender: Any?)
    func splitAtPlayhead(_ sender: Any?)
    func trimStartToPlayhead(_ sender: Any?)
    func trimEndToPlayhead(_ sender: Any?)
    func selectForwardOnTrack(_ sender: Any?)
    func selectForwardOnAllTracks(_ sender: Any?)
    func deleteSelectedClips(_ sender: Any?)
    func rippleDeleteSelected(_ sender: Any?)
    func importMedia(_ sender: Any?)
    func newMediaFolder(_ sender: Any?)
    func showExport(_ sender: Any?)
    func toggleMediaPanel(_ sender: Any?)
    func toggleInspectorPanel(_ sender: Any?)
    func toggleAgentPanel(_ sender: Any?)
    func toggleMaximizePanel(_ sender: Any?)
    func setLayoutDefault(_ sender: Any?)
    func setLayoutMedia(_ sender: Any?)
    func setLayoutVertical(_ sender: Any?)
}
