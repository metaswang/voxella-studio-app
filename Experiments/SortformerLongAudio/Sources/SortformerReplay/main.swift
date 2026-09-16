import Foundation
import MLX
import MLXAudioCore
import MLXAudioVAD

@main
struct SortformerReplay {
    static func main() async throws {
        try await Task.detached {
            let args = CommandLine.arguments
            guard (4...5).contains(args.count), let seconds = Double(args[3]), seconds.isFinite,
                  seconds > 0, seconds <= 7200 else {
                throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: SortformerReplay MODEL_DIRECTORY AUDIO_PATH SECONDS [PROBABILITIES_PATH] (0 < seconds <= 7200)"])
            }
            let model = try SortformerModel.fromModelDirectory(URL(fileURLWithPath: args[1]))
            let (rate, loaded) = try loadAudioArray(from: URL(fileURLWithPath: args[2]), sampleRate: 16000)
            let audio = loaded.ndim > 1 ? mean(loaded, axis: -1) : loaded
            let count = min(audio.dim(0), Int(seconds * Double(rate)))
            let input = audio[..<count]
            eval(input)
            let start = ContinuousClock.now
            var chunks = 0
            var frames = 0
            var probabilityBytes = Data()
            func report(_ phase: String) {
                let elapsed = start.duration(to: .now).components
                let message = "phase=\(phase) seconds=\(Double(count)/Double(rate)) chunks=\(chunks) frames=\(frames) elapsed=\(Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18) active=\(Memory.activeMemory) cache=\(Memory.cacheMemory) peak=\(Memory.peakMemory)\n"
                FileHandle.standardOutput.write(Data(message.utf8))
            }
            report("start")
            for try await result in model.generateStream(
                audio: input, sampleRate: rate, chunkDuration: 15.04,
                minDuration: 0, mergeGap: 0, spkcacheMax: 188, fifoMax: 0
            ) {
                guard let probabilities = result.speakerProbs else {
                    throw NSError(domain: "Replay", code: 2)
                }
                let values = probabilities.asArray(Float.self)
                guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                    throw NSError(domain: "Replay", code: 3)
                }
                if args.count == 5 {
                    values.withUnsafeBytes { probabilityBytes.append(contentsOf: $0) }
                }
                chunks += 1
                frames += probabilities.dim(0)
                report("chunk")
            }
            guard chunks > 0, abs(Double(frames) * 0.08 - Double(count) / Double(rate)) < 0.16 else {
                throw NSError(domain: "Replay", code: 4)
            }
            report("complete")
            if args.count == 5 {
                try probabilityBytes.write(to: URL(fileURLWithPath: args[4]), options: .withoutOverwriting)
            }
        }.value
    }
}
