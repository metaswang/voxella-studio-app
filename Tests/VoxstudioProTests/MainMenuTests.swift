import AppKit
import Testing
@testable import VoxstudioPro

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    @Test func fileAndEditMenusAreVisibleOnlyForTheActiveEditor() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenuBuilder.buildMenu(editorMenusVisible: false)
        let fileItem = try #require(mainMenu.items.first { $0.submenu?.title == "File" })
        let editItem = try #require(mainMenu.items.first { $0.submenu?.title == "Edit" })

        #expect(fileItem.isHidden)
        #expect(editItem.isHidden)

        MainMenuBuilder.setEditorMenusVisible(true, in: mainMenu)
        #expect(!fileItem.isHidden)
        #expect(!editItem.isHidden)

        MainMenuBuilder.setEditorMenusVisible(false, in: mainMenu)
        #expect(fileItem.isHidden)
        #expect(editItem.isHidden)
    }

    @Test func viewMenuProvidesZoomCommandsAndShortcuts() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenuBuilder.buildMenu(editorMenusVisible: false)
        let viewMenu = try #require(mainMenu.items.first { $0.submenu?.title == "View" }?.submenu)

        let increase = try #require(viewMenu.items.first { $0.title == "Zoom In" })
        let decrease = try #require(viewMenu.items.first { $0.title == "Zoom Out" })
        let reset = try #require(viewMenu.items.first { $0.title == "Reset Zoom" })

        #expect(increase.keyEquivalent == "+")
        #expect(increase.keyEquivalentModifierMask == [.command, .shift])
        #expect(decrease.keyEquivalent == "-")
        #expect(decrease.keyEquivalentModifierMask == [.command])
        #expect(reset.keyEquivalent == "0")
        #expect(reset.keyEquivalentModifierMask == [.command, .shift])
    }
}
