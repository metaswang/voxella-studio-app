#if BUNDLED_SPEECH
import Foundation
import MLX
import Synchronization
import AudioCommon
import Testing
@testable import VoxstudioPro

/// Opt-in Nemotron 3 evaluation harnesses.
///
/// RTTM export (score with tools/diarization_eval, collar 0 and 0.25):
///   VOXELLA_NEMOTRON_RTTM_MANIFEST=list.tsv VOXELLA_NEMOTRON_RTTM_OUT=dir scripts/test-local-models.sh \
///     'VoxstudioProTests.Nemotron3EvaluationTests/exportsHypothesisRTTM()'
///   list.tsv rows: `<recording id>\t<absolute audio path>\t<expected speakers or auto>`
///
/// Long-form replay (time, peak memory, cancellation):
///   VOXELLA_NEMOTRON_LONGFORM_MINUTES=60,120 VOXELLA_NEMOTRON_LONGFORM_AUDIO=/path.wav ...
@Suite("Opt-in Nemotron 3 evaluation", .serialized)
struct Nemotron3EvaluationTests {
    static let environment = ProcessInfo.processInfo.environment

    private static func engine() throws -> Nemotron3DiarizationEngine {
        let descriptor = try #require(LocalModelManager.catalog.first { $0.id == .nemotron3Diarization })
        return try Nemotron3DiarizationEngine(
            modelDirectory: LocalModelManager.directory(for: .nemotron3Diarization),
            modelRevision: descriptor.revision
        )
    }

    @Test(.enabled(if: environment["VOXELLA_NEMOTRON_RTTM_MANIFEST"] != nil))
    func exportsHypothesisRTTM() async throws {
        let manifest = try String(contentsOfFile: Self.environment["VOXELLA_NEMOTRON_RTTM_MANIFEST"]!, encoding: .utf8)
        let output = URL(fileURLWithPath: Self.environment["VOXELLA_NEMOTRON_RTTM_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = try Self.engine()
        for row in manifest.split(separator: "\n") where !row.hasPrefix("#") {
            let fields = row.split(separator: "\t").map(String.init)
            guard fields.count >= 2 else { continue }
            let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: fields[1]), targetSampleRate: 16_000)
            let duration = Double(samples.count) / 16_000
            let expected = fields.count > 2 ? Int(fields[2]) : nil
            try await MLXRuntime.beginInference()
            let timeline = try await engine.diarize(
                audio: samples, sampleRate: 16_000, speechRanges: [.init(start: 0, end: duration)],
                policy: .standard(requestedSpeakerCount: expected), progress: { _ in }
            )
            MLXRuntime.endInference()
            let lines = timeline.intervals.map { interval in
                String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> spk%d <NA> <NA>",
                       fields[0], interval.start, interval.end - interval.start, interval.speakerID)
            }
            try (lines.joined(separator: "\n") + "\n")
                .write(to: output.appendingPathComponent("\(fields[0]).rttm"), atomically: true, encoding: .utf8)
            print("NEMOTRON_RTTM id=\(fields[0]) detected=\(timeline.diagnostics.detectedSpeakerCount) "
                + "rtf=\(timeline.diagnostics.realTimeFactor ?? -1)")
        }
    }

    @Test(.enabled(if: environment["VOXELLA_NEMOTRON_LONGFORM_MINUTES"] != nil))
    func longFormReplayReportsTimeMemoryAndCancellation() async throws {
        let source = try AudioFileLoader.load(
            url: URL(fileURLWithPath: try #require(Self.environment["VOXELLA_NEMOTRON_LONGFORM_AUDIO"])),
            targetSampleRate: 16_000
        )
        let engine = try Self.engine()
        for minutes in Self.environment["VOXELLA_NEMOTRON_LONGFORM_MINUTES"]!.split(separator: ",").compactMap({ Int($0) }) {
            let count = minutes * 60 * 16_000
            var audio = [Float]()
            audio.reserveCapacity(count)
            while audio.count < count { audio += source.prefix(count - audio.count) }
            let duration = Double(count) / 16_000
            GPU.resetPeakMemory()
            let residentBefore = Self.residentBytes()
            let started = ContinuousClock.now
            try await MLXRuntime.beginInference()
            let timeline = try await engine.diarize(
                audio: audio, sampleRate: 16_000, speechRanges: [.init(start: 0, end: duration)],
                policy: .standard(requestedSpeakerCount: nil), progress: { _ in }
            )
            MLXRuntime.endInference()
            let elapsed = started.duration(to: .now)
            #expect(timeline.probabilities.count == Int(duration * 100) * 8)
            #expect(timeline.probabilities.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })

            // Cancel halfway through the chunks and time the unwind.
            let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
            let task = Task.detached {
                try await MLXRuntime.beginInference()
                defer { MLXRuntime.endInference() }
                return try await engine.diarize(
                    audio: audio, sampleRate: 16_000, speechRanges: [.init(start: 0, end: duration)],
                    policy: .standard(requestedSpeakerCount: nil)
                ) { update in
                    if update.stage == .diarizing, update.completed == update.total / 2 {
                        cancelledAt.withLock { $0 = .now }
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            let result = await task.result
            let unwind = cancelledAt.withLock { $0 }.map { $0.duration(to: .now) }
            #expect((try? result.get()) == nil)
            print("NEMOTRON_LONGFORM minutes=\(minutes) elapsed=\(elapsed) rtf=\(timeline.diagnostics.realTimeFactor ?? -1) "
                + "chunks=\(timeline.diagnostics.processedChunks) peakMLX=\(Memory.peakMemory) "
                + "residentDelta=\(Self.residentBytes() - residentBefore) cancelUnwind=\(unwind.map { "\($0)" } ?? "n/a") "
                + "detected=\(timeline.diagnostics.detectedSpeakerCount)")
        }
    }

    private static func residentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
#endif
