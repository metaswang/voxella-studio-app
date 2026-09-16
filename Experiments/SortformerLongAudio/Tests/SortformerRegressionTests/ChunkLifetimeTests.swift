import Foundation
import MLX
import Testing
@testable import MLXAudioVAD

@Suite(.serialized)
struct ChunkLifetimeTests {
    private enum Stop: Error { case expected }

    private static func model() throws -> SortformerModel {
        var config = try JSONDecoder().decode(SortformerConfig.self, from: Data("{}".utf8))
        config.fcEncoderConfig.hiddenSize = 16
        config.fcEncoderConfig.subsamplingConvChannels = 8
        config.fcEncoderConfig.numHiddenLayers = 0
        config.tfEncoderConfig.dModel = 16
        config.tfEncoderConfig.encoderLayers = 0
        config.modulesConfig.fcDModel = 16
        config.modulesConfig.tfDModel = 16
        config.modulesConfig.useAosc = true
        config.modulesConfig.chunkRightContext = 1
        return SortformerModel(config)
    }

    @Test func cancellationBeforeProcessingDoesNotEmit() async throws {
        let result = try await Task.detached {
            let model = try Self.model()
            var count = 0
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try model.forEachChunk(audio: MLXArray.zeros([16_000])) { _ in count += 1 }
                return false
            } catch is CancellationError {
                return count == 0
            }
        }.value
        #expect(result)
    }

    @Test func cancellationAtFirstOutputDoesNotEmitLaterChunks() async throws {
        let result = try await Task.detached {
            let model = try Self.model()
            var count = 0
            do {
                try model.forEachChunk(audio: MLXArray.zeros([16_000]), chunkDuration: 0.24) { _ in
                    count += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError {
                return count == 1
            }
        }.value
        #expect(result)
    }

    @Test func consumerFailureReturnsBeforeModelIsReused() throws {
        let model = try Self.model()
        let audio = MLXArray.zeros([16_000])
        var stoppedCount = 0
        #expect(throws: Stop.self) {
            try model.forEachChunk(audio: audio, chunkDuration: 0.24) { _ in
                stoppedCount += 1
                throw Stop.expected
            }
        }
        var completedCount = 0
        try model.forEachChunk(audio: audio, chunkDuration: 0.24) { _ in completedCount += 1 }
        #expect(stoppedCount == 1)
        #expect(completedCount > 1)
    }
}
