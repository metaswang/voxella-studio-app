import Foundation
import Testing
@testable import PalmierPro

#if BUNDLED_SPEECH
import MLX
import MLXAudioSTT

@Suite("Speech input streaming experiment", .serialized)
struct SpeechInputStreamingExperimentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_STREAMING"] == "1"))
    func compareQwenTokenStreaming() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["VOXELLA_SPEECH_INPUT_CORPUS"])
        try await Task.detached {
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            let model = try await Qwen3ASRModel.fromModelDirectory(LocalModelManager.directory(for: .qwen3ASR17B8Bit))
            for name in ["chinese", "chinese-long", "english"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".wav")
                let samples = try await SpeechInputAudio.samples(from: url)
                let audio = MLXArray(samples)
                for pass in 0..<3 {
                    for streaming in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let start = ContinuousClock.now
                        if streaming {
                            var firstToken: Duration?
                            var result: String?
                            for try await event in model.generateStream(audio: audio, maxTokens: 256) {
                                switch event {
                                case .token(let token):
                                    if firstToken == nil, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        firstToken = start.duration(to: .now)
                                    }
                                case .result(let output): result = output.text
                                case .info: break
                                }
                            }
                            print("QWEN_STREAM file=\(name) mode=stream pass=\(pass) first=\(String(describing: firstToken)) elapsed=\(start.duration(to: .now)) text=\(result ?? "")")
                            #expect(result?.isEmpty == false)
                        } else {
                            let output = model.generate(audio: audio, maxTokens: 256)
                            print("QWEN_STREAM file=\(name) mode=offline pass=\(pass) elapsed=\(start.duration(to: .now)) text=\(output.text)")
                            #expect(!output.text.isEmpty)
                        }
                    }
                }
            }
        }.value
    }
}
#endif
