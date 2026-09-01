import Testing
@testable import PalmierPro

@Suite("Parakeet token postprocessing")
struct ParakeetTokenAssemblerTests {
    @Test func joinsSentencePieceFragmentsIntoTimedWords() {
        let tokens = [
            ParakeetTokenAssembler.Token(text: "▁activ", start: 0.0, end: 0.2),
            ParakeetTokenAssembler.Token(text: "iti", start: 0.2, end: 0.3),
            ParakeetTokenAssembler.Token(text: "es", start: 0.3, end: 0.4),
            ParakeetTokenAssembler.Token(text: "▁I", start: 0.5, end: 0.6),
            ParakeetTokenAssembler.Token(text: "'", start: 0.6, end: 0.7),
            ParakeetTokenAssembler.Token(text: "m", start: 0.7, end: 0.8),
            ParakeetTokenAssembler.Token(text: "▁going", start: 0.9, end: 1.1),
            ParakeetTokenAssembler.Token(text: ".", start: 1.1, end: 1.2),
        ]

        let words = ParakeetTokenAssembler.assemble(tokens)

        #expect(words.map(\.text) == ["activities", "I'm", "going."])
        #expect(words.map(\.start) == [0.0, 0.5, 0.9])
        #expect(words.map(\.end) == [0.4, 0.8, 1.2])
    }

    @Test func removesOnlyOverlappingContextDuplicates() {
        let tokens = [
            ParakeetTokenAssembler.Token(text: "▁the", start: 0.0, end: 0.4),
            ParakeetTokenAssembler.Token(text: "▁the", start: 0.35, end: 0.45),
            ParakeetTokenAssembler.Token(text: "▁the", start: 0.5, end: 0.9),
        ]

        let words = ParakeetTokenAssembler.assemble(tokens)

        #expect(words.map(\.text) == ["the", "the"])
        #expect(words.first?.start == 0.0)
        #expect(words.last?.start == 0.5)
    }
}
