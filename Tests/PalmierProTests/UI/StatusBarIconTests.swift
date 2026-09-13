import AppKit
import Testing
@testable import PalmierPro

@Suite("Status bar icon")
struct StatusBarIconTests {
    @Test @MainActor
    func vectorIconLoadsAsAdaptiveTemplate() throws {
        let url = try #require(BundledResource.url("StatusBarIcon.svg"))
        #expect(NSImage(contentsOf: url) != nil)
        let image = try #require(WorkbenchBrandIcon.statusBarImage())

        #expect(image.size == NSSize(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm))
        #expect(image.isTemplate)
    }
}
