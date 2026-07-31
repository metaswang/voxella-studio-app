import AVFoundation
import Foundation

struct DubFlowProgress: Sendable {
    var stage: MediaFlowStage
    var fraction: Double
    var current: Int?
    var total: Int?
    var message: String
}

actor LocalDubFlowRenderer {
    static let shared = LocalDubFlowRenderer()

    private struct PreparedSegment: Sendable {
        var source: DubSegmentPayload
        var chunks: [String]
    }

    private struct GeneratedSegment: Sendable {
        var source: DubSegmentPayload
        var samples: [Float]
    }

    func render(
        payload: DubFlowPayload,
        progress: @escaping @Sendable (DubFlowProgress) -> Void
    ) async throws -> DubFlowResult {
        let prepared = try Self.prepare(payload)
        let chunkCount = prepared.reduce(0) { $0 + $1.chunks.count }
        progress(.init(
            stage: .dubPreprocessing,
            fraction: 0.04,
            current: 0,
            total: chunkCount,
            message: "Prepared \(prepared.count) dub segments"
        ))

        var generated: [GeneratedSegment] = []
        var completedChunks = 0
        for preparedSegment in prepared {
            try Task.checkCancellation()
            let reference = Self.reference(for: preparedSegment.source, payload: payload)
            if reference != nil {
                progress(.init(
                    stage: .dubReference,
                    fraction: 0.06 + 0.04 * Double(completedChunks) / Double(max(1, chunkCount)),
                    current: completedChunks,
                    total: chunkCount,
                    message: "Preparing voice reference"
                ))
            }

            var segmentSamples: [Float] = []
            for chunk in preparedSegment.chunks {
                try Task.checkCancellation()
                let completedBeforeChunk = completedChunks
                let outputURL = try await LocalDubPipeline.shared.synthesize(
                    script: chunk,
                    language: payload.language,
                    model: payload.model,
                    referenceAudioURL: reference?.audioURL,
                    referenceText: reference?.transcript ?? "",
                    progress: { fraction, message in
                        let local = (Double(completedBeforeChunk) + fraction)
                            / Double(max(1, chunkCount))
                        progress(.init(
                            stage: .dubSynthesis,
                            fraction: 0.10 + local * 0.78,
                            current: completedBeforeChunk,
                            total: chunkCount,
                            message: message
                        ))
                    }
                )
                defer { try? FileManager.default.removeItem(at: outputURL) }
                segmentSamples.append(contentsOf: try Self.readMonoSamples(from: outputURL))
                completedChunks += 1
                progress(.init(
                    stage: .dubSynthesis,
                    fraction: 0.10 + 0.78 * Double(completedChunks) / Double(max(1, chunkCount)),
                    current: completedChunks,
                    total: chunkCount,
                    message: "Synthesized chunk \(completedChunks) of \(chunkCount)"
                ))
            }
            generated.append(GeneratedSegment(source: preparedSegment.source, samples: segmentSamples))
        }

        try Task.checkCancellation()
        progress(.init(
            stage: .dubAssembly,
            fraction: 0.90,
            current: generated.count,
            total: generated.count,
            message: "Assembling dub timeline…"
        ))
        let assembly = Self.assemble(
            generated,
            sampleRate: 24_000,
            gapSeconds: max(0, payload.segmentGapSeconds)
        )
        let outputURL = try Self.writeWAV(assembly.samples, sampleRate: 24_000)
        progress(.init(
            stage: .dubAssembly,
            fraction: 1,
            current: generated.count,
            total: generated.count,
            message: "Dub ready"
        ))
        return DubFlowResult(outputURL: outputURL, segments: assembly.segments)
    }

    private static func prepare(_ payload: DubFlowPayload) throws -> [PreparedSegment] {
        let ordered = payload.segments.sorted { $0.index < $1.index }
        var seen = Set<Int>()
        let prepared = try ordered.compactMap { segment -> PreparedSegment? in
            guard seen.insert(segment.index).inserted else {
                throw MediaFlowError.emptyDubScript
            }
            let normalized = normalizeTTSText(segment.text)
            guard !normalized.isEmpty else { return nil }
            let chunks = DubTextChunker.chunks(
                normalized,
                maximumCharacters: max(1, payload.maximumChunkCharacters)
            )
            return chunks.isEmpty ? nil : PreparedSegment(source: segment, chunks: chunks)
        }
        guard !prepared.isEmpty else { throw MediaFlowError.emptyDubScript }
        return prepared
    }

    private static func normalizeTTSText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reference(
        for segment: DubSegmentPayload,
        payload: DubFlowPayload
    ) -> DubVoiceReference? {
        if let segmentReference = payload.segmentReferences[segment.index] {
            return segmentReference
        }
        if let speaker = segment.speaker,
           let speakerReference = payload.speakerReferences[speaker] {
            return speakerReference
        }
        return payload.reference
    }

    private static func readMonoSamples(from URL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL)
        let format = file.processingFormat
        guard format.sampleRate == 24_000,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw LocalAIError.noAudioOutput
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
            throw LocalAIError.noAudioOutput
        }
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        return (0..<frameCount).map { frame in
            (0..<channelCount).reduce(Float.zero) { $0 + channels[$1][frame] }
                / Float(channelCount)
        }
    }

    private static func assemble(
        _ generated: [GeneratedSegment],
        sampleRate: Int,
        gapSeconds: Double
    ) -> (samples: [Float], segments: [DubRenderedSegment]) {
        var output: [Float] = []
        var rendered: [DubRenderedSegment] = []
        var flowCursor = 0.0

        for item in generated {
            let requestedStart = item.source.start.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let start = requestedStart ?? flowCursor
            let startSample = max(0, Int((start * Double(sampleRate)).rounded()))
            let requiredCount = startSample + item.samples.count
            if output.count < requiredCount {
                output.append(contentsOf: repeatElement(0, count: requiredCount - output.count))
            }
            for sampleIndex in item.samples.indices {
                let destination = startSample + sampleIndex
                output[destination] = max(-1, min(1, output[destination] + item.samples[sampleIndex]))
            }
            let end = start + Double(item.samples.count) / Double(sampleRate)
            rendered.append(DubRenderedSegment(
                index: item.source.index,
                text: item.source.text,
                start: start,
                end: end,
                speaker: item.source.speaker,
                sourceSubtitleID: item.source.sourceSubtitleID
            ))
            flowCursor = max(flowCursor, end) + (requestedStart == nil ? gapSeconds : 0)
        }
        return (output, rendered)
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            throw LocalAIError.noAudioOutput
        }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Voxella Studio/Dubs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let URL = directory.appendingPathComponent("dub-flow-\(UUID().uuidString).wav")
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
            }
        }
        let file = try AVAudioFile(forWriting: URL, settings: format.settings)
        try file.write(from: buffer)
        return URL
    }
}

enum DubTextChunker {
    static func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        let maximum = max(1, maximumCharacters)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var sentences: [String] = []
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let remaining = normalized[cursor...]
            let limit = remaining.index(
                remaining.startIndex,
                offsetBy: min(maximum, remaining.count),
                limitedBy: remaining.endIndex
            ) ?? remaining.endIndex
            if limit == remaining.endIndex {
                sentences.append(String(remaining))
                break
            }
            let preferred = remaining[..<limit].lastIndex(where: isBoundary)
            let split = preferred.map { remaining.index(after: $0) } ?? limit
            let piece = String(remaining[..<split])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            cursor = split
            while cursor < normalized.endIndex, normalized[cursor].isWhitespace {
                cursor = normalized.index(after: cursor)
            }
        }
        return sentences
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || ".!?。！？；;：:，,".contains(character)
    }
}
