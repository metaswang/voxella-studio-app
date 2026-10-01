#if BUNDLED_SPEECH
import Foundation
import MLX
import MLXAudioSTS

/// On-device speech enhancement via MossFormer2-SE FP16.
///
/// Recipe from `Experiments/MossFormer2SE_20260918`:
/// full forward when duration < 20 s; otherwise 4 s discard-edges chunks
/// with 0.25 overlap. Output is always at ``sampleRate`` (48 kHz).
actor MossFormerSpeechEnhancer {
    static let shared = MossFormerSpeechEnhancer()
    static let sampleRate = 48_000
    static let fullContextMaxSeconds = 20.0
    static let chunkSeconds: Float = 4.0
    static let chunkOverlapRatio: Float = 0.25

    private var model: MossFormer2SEModel?

    func enhance(audio: [Float], sampleRate: Int) async throws -> [Float] {
        try await LocalModelManager.shared.ensureAudioEnhancementModel()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let model = try await loadedModel()
        return try runRecipe(audio: audio, inputSampleRate: sampleRate, model: model)
    }

    private func loadedModel() async throws -> MossFormer2SEModel {
        if let model { return model }
        try MLXRuntime.requireAvailable()
        let directory = try LocalModelManager.directory(for: .mossFormer2SE)
        let loaded = try MossFormer2SEModel.fromLocal(directory)
        model = loaded
        Log.app.notice("MossFormer2-SE ready sampleRate=\(loaded.sampleRate)")
        return loaded
    }

    private func runRecipe(
        audio: [Float],
        inputSampleRate: Int,
        model: MossFormer2SEModel
    ) throws -> [Float] {
        guard !audio.isEmpty else { return audio }
        let targetRate = model.sampleRate
        let resampled = try VoiceReferenceSpeechGate.resample(
            audio,
            from: Double(inputSampleRate),
            to: Double(targetRate)
        )
        let duration = Double(resampled.count) / Double(targetRate)
        let mlx = MLXArray(resampled)
        let enhanced: [Float]
        if duration < Self.fullContextMaxSeconds {
            let out = try model.enhance(mlx)
            eval(out)
            enhanced = out.asArray(Float.self)
            Memory.clearCache()
        } else {
            enhanced = try enhanceChunkedDiscard(
                audio: mlx,
                model: model,
                chunkSeconds: Self.chunkSeconds,
                overlapRatio: Self.chunkOverlapRatio
            )
        }
        return padOrTrim(enhanced, to: resampled.count)
    }

    private func enhanceChunkedDiscard(
        audio: MLXArray,
        model: MossFormer2SEModel,
        chunkSeconds: Float,
        overlapRatio: Float
    ) throws -> [Float] {
        let input = audio.asArray(Float.self)
        let originalLen = input.count
        let chunkSamples = Int(Float(model.sampleRate) * chunkSeconds)
        let overlapSamples = Int(Float(chunkSamples) * overlapRatio)
        let stride = max(1, chunkSamples - overlapSamples)
        let giveUp = overlapSamples / 2

        if originalLen <= chunkSamples {
            let out = try model.enhance(audio)
            eval(out)
            Memory.clearCache()
            return out.asArray(Float.self)
        }

        var output = [Float](repeating: 0, count: originalLen)
        var starts: [Int] = []
        var current = 0
        while current + chunkSamples <= originalLen {
            starts.append(current)
            current += stride
        }
        if current < originalLen {
            starts.append(current)
        }

        for (idx, startIdx) in starts.enumerated() {
            let isLast = idx == starts.count - 1
            let endIdx = isLast ? originalLen : min(startIdx + chunkSamples, originalLen)
            let chunk = Array(input[startIdx..<endIdx])
            let enhanced = try model.enhance(MLXArray(chunk)).asArray(Float.self)
            eval(MLXArray(enhanced))
            Memory.clearCache()
            let chunkLen = enhanced.count
            let keepStart = (idx == 0) ? 0 : giveUp
            let keepEnd: Int
            if isLast && chunkLen < chunkSamples {
                keepEnd = chunkLen
            } else {
                keepEnd = max(keepStart, chunkLen - giveUp)
            }
            let outputStart = startIdx + keepStart
            let outputEnd = min(startIdx + keepEnd, originalLen)
            let copyCount = outputEnd - outputStart
            if copyCount > 0 {
                output.replaceSubrange(
                    outputStart..<outputEnd,
                    with: enhanced[keepStart..<(keepStart + copyCount)]
                )
            }
        }
        return output
    }

    private func padOrTrim(_ samples: [Float], to count: Int) -> [Float] {
        if samples.count == count { return samples }
        if samples.count > count { return Array(samples.prefix(count)) }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }
}
#endif
