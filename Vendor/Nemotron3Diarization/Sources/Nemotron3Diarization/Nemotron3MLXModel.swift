import Foundation
import MLX
import MLXFast
import MLXNN

private final class Nemotron3RoPE {
    let cosine: MLXArray
    let sine: MLXArray

    init(headDimension: Int = 64, maximumLength: Int) {
        let half = headDimension / 2
        let exponents = MLXArray((0..<half).map { Float(2 * $0) / Float(headDimension) })
        let inverse = MLXArray(Float(1)) / MLX.pow(MLXArray(Float(10_000)), exponents)
        let positions = MLXArray((0..<maximumLength).map(Float.init))
        let frequencies = positions.reshaped(maximumLength, 1) * inverse.reshaped(1, half)
        cosine = concatenated([cos(frequencies), cos(frequencies)], axis: -1)
        sine = concatenated([sin(frequencies), sin(frequencies)], axis: -1)
    }

    /// `[B, H, T, D]`, split-half rotation; positions restart at every call.
    func apply(_ value: MLXArray) -> MLXArray {
        let time = value.dim(2)
        let dimensions = value.dim(3)
        let half = dimensions / 2
        let cosine = cosine[0..<time, 0...].reshaped(1, 1, time, dimensions).asType(value.dtype)
        let sine = sine[0..<time, 0...].reshaped(1, 1, time, dimensions).asType(value.dtype)
        let first = value[0..., 0..., 0..., 0..<half]
        let second = value[0..., 0..., 0..., half..<dimensions]
        return value * cosine + concatenated([-second, first], axis: -1) * sine
    }
}

private final class Nemotron3Attention: Module {
    private let heads = 8
    private let headDimension = 64
    private let scale: Float = 1 / 8
    private let rope: Nemotron3RoPE

    @ModuleInfo(key: "w_qkv") var qkvProjection: Linear
    @ModuleInfo(key: "out_proj") var outputProjection: Linear

    init(rope: Nemotron3RoPE) {
        self.rope = rope
        _qkvProjection.wrappedValue = Linear(512, 1_536, bias: false)
        _outputProjection.wrappedValue = Linear(512, 512, bias: true)
        super.init()
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let batch = input.dim(0)
        let time = input.dim(1)
        let qkv = qkvProjection(input)
            .reshaped(batch, time, 3, heads, headDimension)
            .transposed(2, 0, 3, 1, 4)
        let query = rope.apply(qkv[0])
        let key = rope.apply(qkv[1])
        let attended = MLXFast.scaledDotProductAttention(
            queries: query, keys: key, values: qkv[2], scale: scale, mask: mask
        )
        return outputProjection(attended.transposed(0, 2, 1, 3).reshaped(batch, time, heads * headDimension))
    }
}

private final class Nemotron3FeedForward: Module {
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear

    override init() {
        _linear1.wrappedValue = Linear(512, 2_048, bias: true)
        _linear2.wrappedValue = Linear(2_048, 512, bias: true)
        super.init()
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        linear2(gelu(linear1(input)))
    }
}

private final class Nemotron3Layer: Module {
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo(key: "attn") var attention: Nemotron3Attention
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo(key: "ffn") var feedForward: Nemotron3FeedForward

    init(rope: Nemotron3RoPE) {
        _norm1.wrappedValue = LayerNorm(dimensions: 512, eps: 1.0e-5)
        _attention.wrappedValue = Nemotron3Attention(rope: rope)
        _norm2.wrappedValue = LayerNorm(dimensions: 512, eps: 1.0e-5)
        _feedForward.wrappedValue = Nemotron3FeedForward()
        super.init()
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let attended = input + attention(norm1(input), mask: mask)
        return attended + feedForward(norm2(attended))
    }
}

private final class Nemotron3PreEncoder: Module {
    @ModuleInfo var proj: Linear

    override init() {
        _proj.wrappedValue = Linear(1_024, 512, bias: false)
        super.init()
    }

    /// Stacks eight 10 ms mel rows into one 80 ms row.
    func callAsFunction(_ features: MLXArray) -> MLXArray {
        let time = features.dim(1)
        precondition(time % 8 == 0)
        return proj(features.reshaped(-1, time / 8, 1_024))
    }
}

private final class Nemotron3Encoder: Module {
    @ModuleInfo(key: "pre_encode") var preEncode: Nemotron3PreEncoder
    @ModuleInfo(key: "embed_norm") var embedNorm: LayerNorm
    @ModuleInfo var layers: [Nemotron3Layer]
    @ModuleInfo(key: "final_norm") var finalNorm: LayerNorm

    init(maximumLength: Int) {
        let rope = Nemotron3RoPE(maximumLength: maximumLength)
        _preEncode.wrappedValue = Nemotron3PreEncoder()
        _embedNorm.wrappedValue = LayerNorm(dimensions: 512, eps: 1.0e-5)
        _layers.wrappedValue = (0..<31).map { _ in Nemotron3Layer(rope: rope) }
        _finalNorm.wrappedValue = LayerNorm(dimensions: 512, eps: 1.0e-5)
        super.init()
    }

    func encode(_ embeddings: MLXArray, mask: MLXArray) -> MLXArray {
        var hidden = embedNorm(embeddings)
        for layer in layers {
            hidden = layer(hidden, mask: mask)
        }
        return finalNorm(hidden)
    }
}

private final class Nemotron3Head: Module {
    @ModuleInfo(key: "encoder_proj") var encoderProjection: Linear
    @ModuleInfo(key: "subpixel_upsample") var subpixelUpsample: Conv1d
    @ModuleInfo(key: "first_hidden_to_hidden") var hiddenProjection: Linear
    @ModuleInfo(key: "single_hidden_to_spks") var speakerProjection: Linear

    override init() {
        _encoderProjection.wrappedValue = Linear(512, 192, bias: true)
        _subpixelUpsample.wrappedValue = Conv1d(
            inputChannels: 192, outputChannels: 1_536, kernelSize: 3, padding: 1, bias: true
        )
        _hiddenProjection.wrappedValue = Linear(192, 192, bias: true)
        _speakerProjection.wrappedValue = Linear(192, 8, bias: true)
        super.init()
    }

    func callAsFunction(_ encoded: MLXArray, validLength: Int) -> (high: MLXArray, low: MLXArray) {
        let batch = encoded.dim(0)
        let frames = encoded.dim(1)
        // The reference graph has no rows past the valid length, so its
        // convolution sees zero padding there. Zero those rows explicitly.
        let validRows = (MLXArray(0..<Int32(frames)) .< MLXArray(Int32(validLength)))
            .reshaped(1, frames, 1)
        let projected = encoderProjection(encoded) * validRows.asType(encoded.dtype)
        var hidden = subpixelUpsample(projected)
            .reshaped(batch, frames, 8, 192)
            .reshaped(batch, frames * 8, 192)
        hidden = maximum(hidden, MLXArray(Float(0)))
        hidden = maximum(hiddenProjection(hidden), MLXArray(Float(0)))
        var high = sigmoid(speakerProjection(hidden))
        let validFrames = MLXArray(0..<Int32(frames * 8)) .< MLXArray(Int32(validLength * 8))
        high = high * validFrames.reshaped(1, frames * 8, 1).asType(high.dtype)
        let low = high.reshaped(batch, frames, 8, 8).mean(axis: 2)
        return (high, low)
    }
}

private final class Nemotron3Network: Module {
    @ModuleInfo var encoder: Nemotron3Encoder
    @ModuleInfo(key: "sortformer_modules") var head: Nemotron3Head

    init(maximumLength: Int) {
        _encoder.wrappedValue = Nemotron3Encoder(maximumLength: maximumLength)
        _head.wrappedValue = Nemotron3Head()
        super.init()
    }

    func preencode(_ features: MLXArray) -> MLXArray {
        encoder.preEncode(features)
    }

    func inferHead(_ embeddings: MLXArray, validLength: Int) -> (high: MLXArray, low: MLXArray) {
        let frames = embeddings.dim(1)
        let valid = MLXArray(0..<Int32(frames)) .< MLXArray(Int32(validLength))
        let mask = MLX.where(valid, MLXArray(Float(0)), MLXArray(Float(-10_000))).reshaped(1, 1, 1, frames)
        return head(encoder.encode(embeddings, mask: mask), validLength: validLength)
    }
}

struct Nemotron3HeadOutput {
    /// `[packedCapacity * 8, speakers]` at 10 ms.
    let probabilities10ms: [Float]
    /// `[packedCapacity, speakers]` at 80 ms (mean of the 10 ms rows).
    let probabilities80ms: [Float]
}

protocol Nemotron3InferenceBackend: AnyObject {
    var learnedSilenceEmbedding: [Float] { get }
    func preencode(chunk: [Float]) throws -> [Float]
    func predictHead(packedEmbeddings: [Float], validLength: Int) throws -> Nemotron3HeadOutput
}

final class Nemotron3MLXBackend: Nemotron3InferenceBackend {
    private let network: Nemotron3Network
    private let geometry: Nemotron3Geometry
    let learnedSilenceEmbedding: [Float]

    init(directory: URL, geometry: Nemotron3Geometry = .offline) throws {
        _ = try Nemotron3ArtifactConfiguration.load(from: directory)
        self.geometry = geometry
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw Nemotron3DiarizationError.missingArtifact(weightsURL.path)
        }
        var weights = try MLX.loadArrays(url: weightsURL)
        guard let silence = weights.removeValue(forKey: "sortformer_modules.learnable_sil_emb") else {
            throw Nemotron3DiarizationError.incompatibleWeights("learnable silence embedding is missing")
        }
        let silenceFloat = silence.asType(.float32)
        eval(silenceFloat)
        learnedSilenceEmbedding = silenceFloat.asArray(Float.self)
        guard learnedSilenceEmbedding.count == geometry.modelDimension else {
            throw Nemotron3DiarizationError.incompatibleWeights(
                "learnable silence embedding must contain \(geometry.modelDimension) values")
        }

        var remapped: [String: MLXArray] = [:]
        for (key, value) in weights where key.hasPrefix("encoder.") || key.hasPrefix("sortformer_modules.") {
            let localKey = key
                .replacingOccurrences(of: ".ffn.net.0.", with: ".ffn.linear1.")
                .replacingOccurrences(of: ".ffn.net.3.", with: ".ffn.linear2.")
            remapped[localKey] = value
        }

        let network = Nemotron3Network(maximumLength: geometry.packedCapacity)
        MLXNN.quantize(model: network) { path, _ in
            remapped["\(path).scales"] == nil ? nil : (64, 8, .affine)
        }
        do {
            try network.update(parameters: ModuleParameters.unflattened(remapped), verify: .all)
        } catch {
            throw Nemotron3DiarizationError.incompatibleWeights(error.localizedDescription)
        }
        network.train(false)
        eval(network)
        self.network = network
    }

    func preencode(chunk: [Float]) throws -> [Float] {
        let rows = geometry.fixedChunkMelFrames
        guard chunk.count == rows * geometry.melBins else {
            throw Nemotron3DiarizationError.runtime("pre-encoder expects \(rows) × \(geometry.melBins) values")
        }
        let output = network.preencode(MLXArray(chunk).reshaped(1, rows, geometry.melBins))
        eval(output)
        return output.asType(.float32).asArray(Float.self)
    }

    func predictHead(packedEmbeddings: [Float], validLength: Int) throws -> Nemotron3HeadOutput {
        let capacity = geometry.packedCapacity
        guard packedEmbeddings.count == capacity * geometry.modelDimension,
              (0...capacity).contains(validLength) else {
            throw Nemotron3DiarizationError.runtime("head received invalid packed embeddings")
        }
        let embeddings = MLXArray(packedEmbeddings).reshaped(1, capacity, geometry.modelDimension)
        let output = network.inferHead(embeddings, validLength: validLength)
        eval(output.high, output.low)
        return Nemotron3HeadOutput(
            probabilities10ms: output.high.asType(.float32).asArray(Float.self),
            probabilities80ms: output.low.asType(.float32).asArray(Float.self)
        )
    }
}
