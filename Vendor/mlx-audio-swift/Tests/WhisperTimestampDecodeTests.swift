import Testing
@testable import MLXAudioSTT

@Suite("Whisper timestamp decode")
struct WhisperTimestampDecodeTests {
    private let timestampBegin = 50_364

    @Test func consecutiveTimestampsEmitHonestSegmentTimes() {
        let tokens = [
            timestampBegin,
            100, 101,
            timestampBegin + 100,
            timestampBegin + 100,
            102,
            timestampBegin + 200,
        ]
        let result = WhisperTimestampDecode.decodeWindow(
            tokens: tokens,
            timestampBeginId: timestampBegin,
            remainingDuration: 28,
            decodeText: decode
        )
        #expect(result.segments.count == 2)
        #expect(abs(result.segments[0].start - 0) < 1e-9)
        #expect(abs(result.segments[0].end - 2) < 1e-9)
        #expect(abs(result.segments[1].start - 2) < 1e-9)
        #expect(abs(result.segments[1].end - 4) < 1e-9)
        #expect(result.seekAdvance == 4)
    }

    @Test func earlyLastTimestampSeeksToThatTimeInsteadOfSkippingTheWindow() {
        let tokens = [
            timestampBegin,
            100,
            timestampBegin + 150,
        ]
        let result = WhisperTimestampDecode.decodeWindow(
            tokens: tokens,
            timestampBeginId: timestampBegin,
            remainingDuration: 28,
            decodeText: decode
        )
        #expect(result.segments.count == 1)
        #expect(abs(result.segments[0].end - 3) < 1e-9)
        #expect(abs(result.seekAdvance - 3) < 1e-9)
        #expect(result.seekAdvance < 10)
    }

    @Test func startTimestampOnlyDoesNotSkipTheRestOfTheWindow() {
        let tokens = [timestampBegin, 100, 101]
        let result = WhisperTimestampDecode.decodeWindow(
            tokens: tokens,
            timestampBeginId: timestampBegin,
            remainingDuration: 28,
            decodeText: decode
        )
        #expect(result.segments.count == 1)
        #expect(result.seekAdvance <= WhisperTimestampDecode.minSeekAdvance + 1e-9)
        #expect(result.seekAdvance < 5)
    }

    @Test func missingTimestampsFallBackToTheFullWindow() {
        let result = WhisperTimestampDecode.decodeWindow(
            tokens: [100, 101, 102],
            timestampBeginId: timestampBegin,
            remainingDuration: 28,
            decodeText: decode
        )
        #expect(result.segments.count == 1)
        #expect(abs(result.segments[0].end - 28) < 1e-9)
        #expect(abs(result.seekAdvance - 28) < 1e-9)
    }

    @Test func lastTimestampNearWindowEndConsumesTheWindow() {
        let tokens = [
            timestampBegin,
            100,
            timestampBegin + 1_475,
        ]
        let result = WhisperTimestampDecode.decodeWindow(
            tokens: tokens,
            timestampBeginId: timestampBegin,
            remainingDuration: 30,
            decodeText: decode
        )
        #expect(abs(result.seekAdvance - 30) < 1e-9)
    }

    private func decode(_ tokens: [Int]) -> String {
        tokens.filter { $0 < timestampBegin }.map(String.init).joined(separator: ",")
    }
}
