import Foundation
import Synchronization
import Testing
@testable import VoxstudioPro

#if BUNDLED_SPEECH
@Suite("Speech input experiment", .serialized)
struct SpeechInputBenchmarkTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_INSTALL_SPEECH_INPUT_VAD"] == "1"))
    func installExperimentVAD() async throws {
        let manager = LocalModelManager.shared
        manager.download(.sileroVAD)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while manager.state(for: .sileroVAD).isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(manager.state(for: .sileroVAD).isInstalled)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_CANCELLATION"] == "1"))
    func cancellationDuringPreviewReleasesInference() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_CORPUS"])
        let url = URL(fileURLWithPath: directory).appendingPathComponent("chinese.wav")
        let startGate = AsyncSemaphore(value: 0)
        let holder = Mutex<Task<SpeechInputResult, Error>?>(nil)
        let operation = Task {
            try await startGate.wait()
            return try await LocalSpeechPipeline.shared.recognizeInput(sourceURL: url) { update in
                if update.partialText?.isEmpty == false { holder.withLock { $0?.cancel() } }
            }
        }
        holder.withLock { $0 = operation }
        await startGate.signal()
        do {
            _ = try await operation.value
            Issue.record("Cancelled recognition committed a result")
        } catch is CancellationError {
            print("SPEECH_CANCELLATION cancelled during preview")
        }
        holder.withLock { $0 = nil }
        let next = try await LocalSpeechPipeline.shared.recognizeInput(sourceURL: url) { _ in }
        #expect(!next.text.isEmpty)
        print("SPEECH_CANCELLATION subsequent inference completed")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_EXPERIMENT"] == "1"))
    func compareReferenceAudioLatency() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_CORPUS"])
        let urls = try await Task.detached {
            try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
        #expect(!urls.isEmpty)
        for url in urls {
            for pass in 0..<3 {
                for mode in (pass.isMultiple(of: 2) ? ["timed", "text"] : ["text", "timed"]) {
                    let start = ContinuousClock.now
                    if mode == "text" {
                        let firstPreview = Mutex<Duration?>(nil)
                        let result = try await LocalSpeechPipeline.shared.recognizeInput(sourceURL: url) { update in
                            if update.partialText?.isEmpty == false {
                                firstPreview.withLock { if $0 == nil { $0 = start.duration(to: .now) } }
                            }
                        }
                        print("SPEECH_PREVIEW file=\(url.lastPathComponent) pass=\(pass) first=\(String(describing: firstPreview.withLock { $0 }))")
                        print("SPEECH_INPUT file=\(url.lastPathComponent) mode=text pass=\(pass) elapsed=\(start.duration(to: .now)) engine=\(result.engine.rawValue) language=\(result.languageCode ?? "unknown") text=\(result.text)")
                        #expect(!result.text.isEmpty)
                        #expect(result.languageCode != nil)
                    } else {
                        let result = try await LocalSpeechPipeline.shared.transcribe(
                            sourceURL: url, languageCode: nil, speakerCount: 1, clipRangeSeconds: 0...10,
                            progressUpdate: { _ in }
                        )
                        print("SPEECH_INPUT file=\(url.lastPathComponent) mode=timed pass=\(pass) elapsed=\(start.duration(to: .now)) text=\(result.text)")
                    }
                }
            }
        }
    }
}
#endif
