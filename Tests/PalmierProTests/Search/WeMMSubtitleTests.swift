#if BUNDLED_SPEECH

import Testing
@testable import PalmierPro

@Suite("WeMM subtitle parsing")
struct WeMMSubtitleTests {
    @Test func parsesAndCleansTimedCues() throws {
        let track = try WeMMSubtitleTrack.parse(
            """
            1
            00:00:01,200 --> 00:00:02,500
            <i>脚底</i> 很痛

            2
            00:00:03.000 --> 00:00:04.000 X1:2
            {\\an8}在家里使用
            """)

        #expect(track.cues.count == 2)
        #expect(track.cues[0].text == "脚底 很痛")
        #expect(track.text(overlapping: 1.5 ... 3.2) == "脚底 很痛 在家里使用")
    }

    @Test func rejectsInvalidCueRanges() {
        #expect(throws: WeMMSubtitleTrack.Error.self) {
            try WeMMSubtitleTrack.parse(
                """
                1
                00:00:02,000 --> 00:00:01,000
                无效
                """)
        }
    }
}

#endif
