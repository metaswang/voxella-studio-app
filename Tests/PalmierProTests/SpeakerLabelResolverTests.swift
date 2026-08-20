import Testing
@testable import PalmierPro

@Suite("Speaker label resolver")
struct SpeakerLabelResolverTests {
    @Test(arguments: [
        (nil, nil),
        ("", nil),
        ("  \n", nil),
        (" Speaker 1 ", "Speaker 1"),
    ] as [(String?, String?)])
    func normalization(value: String?, expected: String?) {
        #expect(SpeakerLabelResolver.normalized(value) == expected)
    }

    @Test func dominantSpeakerUsesFrequencyThenFirstAppearance() {
        #expect(
            SpeakerLabelResolver.dominant(in: ["B", "A", "A", "B"]) == "B"
        )
        #expect(
            SpeakerLabelResolver.dominant(in: [nil, " ", "A", "A", "B"]) == "A"
        )
        #expect(SpeakerLabelResolver.dominant(in: [nil, " "]) == nil)
    }
}
