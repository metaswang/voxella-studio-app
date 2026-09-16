import Foundation
import MLX
import Testing
@testable import MLXAudioVAD

@Suite(.serialized)
struct ContextParityTests {
    @Test(arguments: [1, 7, 8, 9, 15, 16, 17, 1504, 1505, 3013], ["float32", "float16", "mixed"])
    func boundedContextMatchesFullConvolution(frameCount: Int, precision: String) throws {
        let config = try JSONDecoder().decode(FCEncoderConfig.self, from: Data(
            #"{"hidden_size":16,"subsampling_conv_channels":8,"num_mel_bins":128}"#.utf8
        ))
        let encoder = ConvSubsampling(config)
        if precision != "float32" {
            encoder.update(parameters: encoder.mapParameters { $0.asType(.float16) })
        }
        let features = sin(MLXArray(0..<(128 * frameCount)).asType(.float32) * 0.013)
            .reshaped(1, 128, frameCount)
            .asType(precision == "float16" ? .float16 : .float32)
        let (full, _) = encoder(features, lengths: MLXArray([Int32(frameCount)]))
        eval(full)
        let count = full.dim(1)
        let starts = Set([0, min(1, count - 1), count / 2, max(0, count - 2), count - 1])
        for start in starts.sorted() {
            let range = start..<min(count, start + 2)
            let bounded = encoder.embeddings(features, in: range)
            let reference = full[0..., range, 0...]
            #expect(bounded.shape == reference.shape)
            let error = abs(bounded - reference).max().item(Float.self)
            #expect(error.isFinite)
            #expect(error < (precision == "float16" ? 0.002 : 0.0001))
        }
    }
}
