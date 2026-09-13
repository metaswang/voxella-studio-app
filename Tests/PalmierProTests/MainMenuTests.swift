import AppKit
import Testing
@testable import PalmierPro

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
}
