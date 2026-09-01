#if BUNDLED_SPEECH

import Testing
@testable import PalmierPro

@Suite("WeMM embedding math")
struct WeMMEmbeddingMathTests {
    @Test func normalizesAndAppliesMatryoshkaDimension() throws {
        var values = Array(repeating: Float(0), count: 2048)
        values[0] = 3
        values[1] = 4

        let embedding = try WeMMEmbeddingMath.normalizeAndTruncate(values, dimension: 64)

        #expect(embedding.count == 64)
        #expect(abs(embedding[0] - 0.6) < 0.0001)
        #expect(abs(embedding[1] - 0.8) < 0.0001)
        #expect(abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001)
    }

    @Test func rejectsUnsupportedDimensionsAndInvalidVectors() {
        #expect(throws: WeMMEmbeddingMath.Error.self) {
            try WeMMEmbeddingMath.normalizeAndTruncate(Array(repeating: Float(1), count: 64), dimension: 32)
        }
        #expect(throws: WeMMEmbeddingMath.Error.self) {
            try WeMMEmbeddingMath.normalizeAndTruncate(Array(repeating: Float(0), count: 64), dimension: 64)
        }
    }

}

#endif
