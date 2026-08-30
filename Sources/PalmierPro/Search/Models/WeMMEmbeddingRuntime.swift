// MLX runtime for WeMM text/image/video embeddings.

#if BUNDLED_SPEECH

import Foundation
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

enum WeMMEmbeddingMath {
    enum Error: LocalizedError {
        case invalidDimension(Int, supported: [Int])
        case invalidVector

        var errorDescription: String? {
            switch self {
            case .invalidDimension(let dimension, let supported):
                "Embedding dimension \(dimension) is unsupported; use one of \(supported)."
            case .invalidVector:
                "Embedding contains a non-finite value or has zero norm."
            }
        }
    }

    static func normalizeAndTruncate(
        _ values: [Float],
        dimension: Int
    ) throws -> [Float] {
        let supported = [64, 128, 256, 512, 1024, 2048].filter { $0 <= values.count }
        guard supported.contains(dimension) else {
            throw Error.invalidDimension(dimension, supported: supported)
        }
        guard values.allSatisfy(\.isFinite) else { throw Error.invalidVector }

        let fullNorm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard fullNorm.isFinite, fullNorm > 0 else { throw Error.invalidVector }
        var output = values.map { $0 / fullNorm }

        if dimension < output.count {
            output = Array(output.prefix(dimension))
            let truncatedNorm = sqrt(output.reduce(0) { $0 + $1 * $1 })
            guard truncatedNorm.isFinite, truncatedNorm > 0 else { throw Error.invalidVector }
            output = output.map { $0 / truncatedNorm }
        }
        return output
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.greatestFiniteMagnitude }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

actor WeMMEmbeddingRuntime {
    enum Error: LocalizedError {
        case missingFile(String)
        case invalidModelDimension
        case invalidOutputShape([Int])

        var errorDescription: String? {
            switch self {
            case .missingFile(let name): "WeMM model is missing \(name)."
            case .invalidModelDimension: "WeMM model hidden size is invalid."
            case .invalidOutputShape(let shape): "Unexpected WeMM output shape: \(shape)."
            }
        }
    }

    private let model: WeMMQwen35EmbeddingModel
    private let processor: WeMMEmbeddingInputProcessor
    private let hiddenSize: Int

    private init(
        model: WeMMQwen35EmbeddingModel,
        processor: WeMMEmbeddingInputProcessor,
        hiddenSize: Int
    ) {
        self.model = model
        self.processor = processor
        self.hiddenSize = hiddenSize
    }

    static func load(
        from directory: URL,
        maxFrames: Int = 8,
        resizeEdge: Int = 512
    ) async throws -> WeMMEmbeddingRuntime {
        let configURL = directory.appendingPathComponent("config.json")
        let templateURL = directory.appendingPathComponent("embedding_chat_template.jinja")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw Error.missingFile("config.json")
        }
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw Error.missingFile("embedding_chat_template.jinja")
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder.json5().decode(
            WeMMQwen35Configuration.self,
            from: configData)
        let baseConfig = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let hiddenSize = config.textConfiguration.hiddenSize
        guard hiddenSize > 0 else { throw Error.invalidModelDimension }

        let model = WeMMQwen35EmbeddingModel(config)
        try loadWeights(
            modelDirectory: directory,
            model: model,
            perLayerQuantization: baseConfig.perLayerQuantization)

        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let processor = try WeMMEmbeddingInputProcessor(
            tokenizer: tokenizer,
            chatTemplate: template,
            maxFrames: maxFrames,
            resizeEdge: resizeEdge)
        return WeMMEmbeddingRuntime(
            model: model,
            processor: processor,
            hiddenSize: hiddenSize)
    }

    func encode(text: String, dimension: Int) throws -> [Float] {
        try encode(input: processor.textInput(text), dimension: dimension)
    }

    func encode(image: CIImage, text: String? = nil, dimension: Int) throws -> [Float] {
        try encode(input: processor.imageInput(image, text: text), dimension: dimension)
    }

    func encode(videoURL: URL, text: String? = nil, dimension: Int) async throws -> [Float] {
        let input = try await processor.videoInput(videoURL, text: text)
        return try encode(input: input, dimension: dimension)
    }

    func encode(
        videoURL: URL,
        timeRange: ClosedRange<Double>,
        text: String? = nil,
        dimension: Int
    ) async throws -> [Float] {
        let input = try await processor.videoInput(
            videoURL,
            timeRange: timeRange,
            text: text)
        return try encode(input: input, dimension: dimension)
    }

    private func encode(input: LMInput, dimension: Int) throws -> [Float] {
        let hidden = try model.embedding(input)
        guard hidden.ndim == 3, hidden.dim(0) == 1, hidden.dim(1) > 0,
            hidden.dim(2) == hiddenSize
        else {
            throw Error.invalidOutputShape(hidden.shape)
        }
        let last = hidden[0, hidden.dim(1) - 1, 0...]
        eval(last)
        return try WeMMEmbeddingMath.normalizeAndTruncate(
            last.asArray(Float.self),
            dimension: dimension)
    }
}

#endif
