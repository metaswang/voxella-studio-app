import Foundation
import Testing
@testable import PalmierPro

@Suite("Clip range loading")
struct ClipRangeControlTests {
    @Test func expandsDefaultPlaceholderToLoadedMediaDuration() {
        let range = ClipRangeControl.rangeAfterLoadingMedia(
            current: 0...1,
            duration: 196.63,
            expandsPlaceholderRange: true
        )

        #expect(range == 0...196.63)
    }

    @Test func preservesExplicitOneSecondRange() {
        let range = ClipRangeControl.rangeAfterLoadingMedia(
            current: 0...1,
            duration: 196.63,
            expandsPlaceholderRange: false
        )

        #expect(range == 0...1)
    }

    @Test func rangeBeyondMediaDurationResetsToLoadedMediaDuration() {
        let range = ClipRangeControl.rangeAfterLoadingMedia(
            current: 20...300,
            duration: 196.63,
            expandsPlaceholderRange: false
        )

        #expect(range == 0...196.63)
    }
}
