import Foundation
import Testing
@testable import Nemotron3Diarization

/// Runs the real MLX INT8 bundle when `NEMOTRON3_MODEL_DIR` points at it.
@Suite struct Nemotron3ModelTests {
    static let modelDirectory = ProcessInfo.processInfo.environment["NEMOTRON3_MODEL_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    @Test(.enabled(if: modelDirectory != nil))
    func multiChunkOutputHasOneRowPerTenMilliseconds() throws {
        let diarizer = try Nemotron3Diarizer(modelDirectory: Self.modelDirectory!)
        // 62 s → three chunks, including a short tail.
        let count = 16_000 * 62 + 77
        var generator = SystemRandomNumberGenerator()
        let audio = (0..<count).map { index -> Float in
            let t = Double(index) / 16_000
            let voiced = Float(sin(2 * .pi * (t < 31 ? 140 : 220) * t)) * 0.2
            return voiced + Float.random(in: -0.01...0.01, using: &generator)
        }
        var progress: [Int] = []
        let probabilities = try diarizer.activityProbabilities(audio: audio) { done, total in
            progress.append(done)
            #expect(total == 3)
        }
        #expect(progress == [1, 2, 3])
        #expect(probabilities.count == diarizer.geometry.frameCount(sampleCount: count) * 8)
        #expect(probabilities.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    @Test(.enabled(if: modelDirectory != nil))
    func cancellationFromProgressStopsWithoutResult() throws {
        struct Stop: Error {}
        let diarizer = try Nemotron3Diarizer(modelDirectory: Self.modelDirectory!)
        let audio = [Float](repeating: 0.001, count: 16_000 * 60)
        #expect(throws: Stop.self) {
            _ = try diarizer.activityProbabilities(audio: audio) { _, _ in throw Stop() }
        }
    }

    @Test(.enabled(if: modelDirectory != nil))
    func emptyAudioReturnsNoFrames() throws {
        let diarizer = try Nemotron3Diarizer(modelDirectory: Self.modelDirectory!)
        #expect(try diarizer.activityProbabilities(audio: []).isEmpty)
        #expect(try diarizer.activityProbabilities(audio: [Float](repeating: 0, count: 100)).isEmpty)
    }
}
