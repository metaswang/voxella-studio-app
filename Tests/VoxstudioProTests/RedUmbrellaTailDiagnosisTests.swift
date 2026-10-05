import Foundation
import Testing
@testable import VoxstudioPro

#if BUNDLED_SPEECH
import AudioCommon
import MLX
@testable import MLXAudioTTS

/// One opt-in replay of the missing-word block; the original A/B artifacts remain unchanged.
@Suite("Red Umbrella tail stop and decode diagnosis", .serialized)
struct RedUmbrellaTailDiagnosisTests {
    private static let enabled = ProcessInfo.processInfo.environment["VOXSTUDIO_RED_UMBRELLA_STOP_CHECK"] == "1"

    private struct Input: Decodable {
        let jobID: String
        let script: String
        let reference: DubVoiceReference
        let modelPath: String
        let outputDirectory: String
    }

    private struct Manifest: Decodable {
        struct Chunk: Decodable { let id: String; let text: String; let filename: String }
        let chunks: [Chunk]
    }

    private struct Diagnosis: Encodable {
        let text: String
        let seed: UInt64
        let textTokenCount: Int
        let effectiveMaxTokens: Int
        let generatedCodecFrames: Int
        let lastToken: Int?
        let eosToken: Int
        let stopReason: String
        let referenceCodecFrames: Int
        let referenceZeroFrames: Int
        let generatedZeroFrames: Int
        let decodeUpsampleRate: Int
        let untrimmedGeneratedFrames: Int
        let actualOutputFrames: Int
        let expectedOutputFramesWithCurrentTrim: Int
        let decoderTailRemovedFrames: Int
        let decoderTailRemovedSeconds: Double
        let identicalToSavedRaw: Bool
        let replaySeconds: Double
        let firstCodebookTokensIncludingEOS: [Int]
    }

    @Test(.enabled(if: enabled))
    func inspectStopAndLengthCropping() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXSTUDIO_RED_UMBRELLA_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = URL(fileURLWithPath: input.outputDirectory, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let block = try #require(manifest.chunks.first { $0.id == "B-2" })
        let seed = DubSeed.deterministic(language: "en", text: "\(input.jobID)\n\(input.script)")
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference(); MLXRuntime.releaseActivations() }
        let model = try #require(try await TTS.loadModel(modelRepo: input.modelPath) as? Qwen3TTSModel)
        let parameters = model.defaultGenerationParameters
        let referenceSamples = try AudioFileLoader.load(url: input.reference.audioURL, targetSampleRate: 24_000)
        let reference = MLXArray(referenceSamples)
        var tokens = [Int]()
        MLXRandom.seed(seed)
        let started = Date()
        let output = try model.generateVoiceDesign(text: block.text, instruct: nil, language: "english",
            refAudio: reference, refText: input.reference.transcript, temperature: parameters.temperature,
            topK: parameters.topK, topP: parameters.topP, repetitionPenalty: parameters.repetitionPenalty ?? 1.05,
            minP: parameters.minP, maxTokens: parameters.maxTokens ?? 4096,
            onToken: { tokens.append($0) })
        let samples = output.asArray(Float.self)
        let seconds = Date().timeIntervalSince(started)
        let eos = try #require(model.config.talkerConfig?.codecEosTokenId)
        let generated = tokens.last == eos ? Array(tokens.dropLast()) : tokens
        // Called after generation, with the same reference object: reads the already cached codes.
        let conditioning = try model.prepareReferenceConditioning(refAudio: reference,
            refText: input.reference.transcript, language: "english")
        let refCodes = conditioning.referenceSpeechCodes
        let refCount = refCodes.dim(2)
        let refZeros = Int((refCodes[0..., 0, 0...] .== 0).sum().item(Int32.self))
        let generatedZeros = generated.filter { $0 == 0 }.count
        let upsample = try #require(model.speechTokenizer?.decodeUpsampleRate)
        let totalCount = refCount + generated.count
        let validLength = (totalCount - refZeros - generatedZeros) * upsample
        let referenceCut = Int(Double(refCount) / Double(totalCount) * Double(validLength))
        let expected = validLength - referenceCut
        let saved = try AudioFileLoader.load(url: directory.appendingPathComponent(block.filename), targetSampleRate: 24_000)
        let textTokens = try #require(model.tokenizer).encode(text: block.text).count
        let limit = min(parameters.maxTokens ?? 4096, max(75, textTokens * 6))
        let diagnosis = Diagnosis(text: block.text, seed: seed, textTokenCount: textTokens,
            effectiveMaxTokens: limit, generatedCodecFrames: generated.count, lastToken: tokens.last,
            eosToken: eos, stopReason: tokens.last == eos ? "EOS" : "token_limit",
            referenceCodecFrames: refCount, referenceZeroFrames: refZeros, generatedZeroFrames: generatedZeros,
            decodeUpsampleRate: upsample, untrimmedGeneratedFrames: generated.count * upsample,
            actualOutputFrames: samples.count, expectedOutputFramesWithCurrentTrim: expected,
            decoderTailRemovedFrames: generated.count * upsample - samples.count,
            decoderTailRemovedSeconds: Double(generated.count * upsample - samples.count) / 24_000,
            identicalToSavedRaw: samples == saved, replaySeconds: seconds, firstCodebookTokensIncludingEOS: tokens)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(diagnosis).write(to: directory.appendingPathComponent("B-tail-stop-diagnosis.json"), options: .atomic)
        print("[umbrella-tail] stop=\(diagnosis.stopReason) generated=\(generated.count)/\(limit) refZeros=\(refZeros) generatedZeros=\(generatedZeros) tailLoss=\(diagnosis.decoderTailRemovedSeconds)s sameRaw=\(diagnosis.identicalToSavedRaw)")
        #expect(samples.count == expected)
        #expect(samples == saved)
    }
}
#endif
