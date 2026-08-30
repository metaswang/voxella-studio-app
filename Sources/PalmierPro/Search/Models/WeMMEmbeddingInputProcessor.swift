// WeMM input preparation: official embedding template plus Qwen3.5 visual packing.

#if BUNDLED_SPEECH

import AVFoundation
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

struct WeMMEmbeddingInputProcessor {
    enum Error: LocalizedError {
        case missingToken(String)
        case placeholderCount(expected: Int, actual: Int)
        case emptyVideo
        case unsupportedImageSize

        var errorDescription: String? {
            switch self {
            case .missingToken(let token): "Tokenizer is missing special token \(token)."
            case .placeholderCount(let expected, let actual):
                "Expected \(expected) visual placeholder(s), found \(actual)."
            case .emptyVideo: "Video did not produce any decodable frames."
            case .unsupportedImageSize: "Image dimensions must be positive and divisible by 16."
            }
        }
    }

    private enum VisualKind {
        case image
        case video

        var contentType: String {
            switch self {
            case .image: "image"
            case .video: "video"
            }
        }

        var placeholder: String {
            switch self {
            case .image: "<|image_pad|>"
            case .video: "<|video_pad|>"
            }
        }
    }

    private let tokenizer: any Tokenizers.Tokenizer
    private let chatTemplate: String
    private let maxFrames: Int
    private let resizeEdge: Int

    init(
        tokenizer: any Tokenizers.Tokenizer,
        chatTemplate: String,
        maxFrames: Int = 8,
        resizeEdge: Int = 512
    ) throws {
        guard maxFrames > 0, resizeEdge > 0 else {
            throw Error.unsupportedImageSize
        }
        self.tokenizer = tokenizer
        self.chatTemplate = chatTemplate
        self.maxFrames = maxFrames
        self.resizeEdge = resizeEdge
    }

    func textInput(_ text: String) throws -> LMInput {
        let tokens = try makePromptTokens(kind: nil, text: text)
        return makeTextInput(tokens)
    }

    func imageInput(_ image: CIImage, text: String? = nil) throws -> LMInput {
        let normalized = normalize(image)
        let (pixels, frame) = try patchify(images: [MediaProcessing.asMLXArray(normalized)])
        let tokens = try makePromptTokens(kind: .image, text: text)
        return LMInput(
            text: .init(tokens: tokens, mask: ones(like: tokens).asType(.int8)),
            image: .init(pixels: pixels, frames: [frame]))
    }

    func videoInput(_ url: URL, text: String? = nil) async throws -> LMInput {
        let sequence = try await MediaProcessing.asProcessedSequence(
            .url(url),
            targetFPS: { _ in 2.0 },
            maxFrames: maxFrames
        ) { frame in
            .init(frame: normalize(frame.frame), timeStamp: frame.timeStamp)
        }

        guard !sequence.frames.isEmpty else { throw Error.emptyVideo }
        let (pixels, frame) = try patchify(images: sequence.frames)
        let tokens = try makePromptTokens(kind: .video, text: text, visualFrame: frame)
        return LMInput(
            text: .init(tokens: tokens, mask: ones(like: tokens).asType(.int8)),
            video: .init(pixels: pixels, frames: [frame]))
    }

    func videoInput(
        _ url: URL,
        timeRange: ClosedRange<Double>,
        text: String? = nil
    ) async throws -> LMInput {
        guard timeRange.lowerBound.isFinite, timeRange.upperBound.isFinite,
            timeRange.lowerBound >= 0, timeRange.upperBound > timeRange.lowerBound
        else {
            throw Error.emptyVideo
        }

        let images = try await sampleVideoImages(url: url, timeRange: timeRange)
        let arrays = images.map { MediaProcessing.asMLXArray(normalize($0)) }
        let (pixels, frame) = try patchify(images: arrays)
        let tokens = try makePromptTokens(kind: .video, text: text, visualFrame: frame)
        return LMInput(
            text: .init(tokens: tokens, mask: ones(like: tokens).asType(.int8)),
            video: .init(pixels: pixels, frames: [frame]))
    }

    private func normalize(_ image: CIImage) -> CIImage {
        let fitted = MediaProcessing.bestFit(
            image.extent.size,
            in: CGSize(width: resizeEdge, height: resizeEdge))
        let resizedSize = CGSize(
            width: alignedDimension(fitted.width),
            height: alignedDimension(fitted.height))
        let resized = MediaProcessing.resampleBicubic(image, to: resizedSize)
        return MediaProcessing.normalize(
            resized,
            mean: (0.5, 0.5, 0.5),
            std: (0.5, 0.5, 0.5))
    }

    private func alignedDimension(_ value: CGFloat) -> CGFloat {
        max(32, floor(value / 32) * 32)
    }

    private func makeTextInput(_ tokens: MLXArray) -> LMInput {
        LMInput(text: .init(tokens: tokens, mask: ones(like: tokens).asType(.int8)))
    }

    private func makePromptTokens(
        kind: VisualKind?,
        text: String?,
        visualFrame: THW? = nil
    ) throws -> MLXArray {
        var content = [[String: any Sendable]]()
        if let kind {
            content.append(["type": kind.contentType])
        }
        if let text, !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        if content.isEmpty {
            content.append(["type": "text", "text": ""])
        }

        let messages: [[String: any Sendable]] = [[
            "role": "user",
            "content": content
        ]]
        var promptTokens = try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: .literal(chatTemplate),
            addGenerationPrompt: false,
            truncation: false,
            maxLength: nil,
            tools: nil)

        guard let kind else {
            let array = MLXArray(promptTokens).expandedDimensions(axis: 0)
            return array
        }
        guard let visualFrame else {
            throw Error.emptyVideo
        }

        let paddingToken = try specialTokenId(kind.placeholder)
        let replacementCount = visualFrame.product / 4
        guard replacementCount > 0 else { throw Error.unsupportedImageSize }

        let replacement: [Int]
        switch kind {
        case .image:
            replacement = Array(repeating: paddingToken, count: replacementCount)
        case .video:
            let start = try specialTokenId("<|vision_start|>")
            let end = try specialTokenId("<|vision_end|>")
            replacement = [start] + Array(repeating: paddingToken, count: replacementCount) + [end]
        }

        let occurrences = promptTokens.filter { $0 == paddingToken }.count
        guard occurrences == 1 else {
            throw Error.placeholderCount(expected: 1, actual: occurrences)
        }
        if let index = promptTokens.firstIndex(of: paddingToken) {
            promptTokens.replaceSubrange(index ... index, with: replacement)
        }
        return MLXArray(promptTokens).expandedDimensions(axis: 0)
    }

    private func specialTokenId(_ token: String) throws -> Int {
        guard let id = tokenizer.convertTokenToId(token) else {
            throw Error.missingToken(token)
        }
        return id
    }

    private func sampleVideoImages(
        url: URL,
        timeRange: ClosedRange<Double>
    ) async throws -> [CIImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { throw Error.emptyVideo }

        let start = min(timeRange.lowerBound, durationSeconds)
        let end = min(timeRange.upperBound, durationSeconds)
        guard end > start else { throw Error.emptyVideo }

        let count = max(1, maxFrames)
        let times = (0 ..< count).map { index in
            let fraction = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            return CMTime(seconds: start + (end - start) * fraction, preferredTimescale: 600)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var images: [CIImage] = []
        for await result in generator.images(for: times) {
            switch result {
            case .success(requestedTime: _, let image, actualTime: _):
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                    throw Error.emptyVideo
                }
                images.append(CIImage(cgImage: image, options: [.colorSpace: colorSpace]))
            case .failure:
                continue
            }
        }
        guard !images.isEmpty else { throw Error.emptyVideo }
        return images
    }

    private func patchify(images: [MLXArray]) throws -> (MLXArray, THW) {
        guard let first = images.first else { throw Error.emptyVideo }
        let height = first.dim(-2)
        let width = first.dim(-1)
        guard height > 0, width > 0, height % 16 == 0, width % 16 == 0 else {
            throw Error.unsupportedImageSize
        }

        var patches = concatenated(images)
        let temporalPatchSize = 2
        let remainder = patches.dim(0) % temporalPatchSize
        if remainder != 0 {
            let last = patches[-1, .ellipsis]
            patches = concatenated([
                patches,
                tiled(last, repetitions: [temporalPatchSize - remainder, 1, 1, 1])
            ])
        }

        let channels = patches.dim(1)
        let gridT = patches.dim(0) / temporalPatchSize
        let gridH = height / 16
        let gridW = width / 16
        let mergeSize = 2
        guard gridH % mergeSize == 0, gridW % mergeSize == 0 else {
            throw Error.unsupportedImageSize
        }

        patches = patches.reshaped(
            gridT,
            temporalPatchSize,
            channels,
            gridH / mergeSize,
            mergeSize,
            16,
            gridW / mergeSize,
            mergeSize,
            16)
        patches = patches.transposed(0, 3, 6, 4, 7, 2, 1, 5, 8)
        patches = patches.reshaped(
            gridT * gridH * gridW,
            channels * temporalPatchSize * 16 * 16)
        return (patches, .init(gridT, gridH, gridW))
    }
}

#endif
