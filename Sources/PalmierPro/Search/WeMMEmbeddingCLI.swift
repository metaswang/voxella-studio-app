// Command-line evaluation harness for WeMM video/text retrieval.

#if BUNDLED_SPEECH

import AVFoundation
import Foundation

enum WeMMEmbeddingCLI {
    private struct Options {
        let modelDirectory: URL
        let videoURL: URL
        let dimension: Int
        let framesPerSegment: Int
        let segmentCount: Int
        let subtitleURL: URL?
        let queries: [String]

        init(arguments: [String]) throws {
            var modelDirectory: URL?
            var videoURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Downloads/signal-2026-08-14-17-26-29-163.mp4")
            var dimension = 256
            var framesPerSegment = 4
            var segmentCount = 6
            var subtitleURL: URL?
            var queries: [String] = []

            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--wemm-eval":
                    break
                case "--model-dir":
                    index += 1
                    modelDirectory = URL(fileURLWithPath: try Self.value(arguments, index))
                case "--video":
                    index += 1
                    videoURL = URL(fileURLWithPath: try Self.value(arguments, index))
                case "--dimension":
                    index += 1
                    dimension = try Self.intValue(arguments, index)
                case "--frames":
                    index += 1
                    framesPerSegment = try Self.intValue(arguments, index)
                case "--segments":
                    index += 1
                    segmentCount = try Self.intValue(arguments, index)
                case "--srt":
                    index += 1
                    subtitleURL = URL(fileURLWithPath: try Self.value(arguments, index))
                case "--query":
                    index += 1
                    queries.append(try Self.value(arguments, index))
                case "--help", "-h":
                    throw CLIError.help
                default:
                    throw CLIError.unknownArgument(argument)
                }
                index += 1
            }

            guard dimension > 0, framesPerSegment > 0, framesPerSegment <= 64,
                segmentCount > 0, segmentCount <= 64
            else {
                throw CLIError.invalidOptions
            }
            if modelDirectory == nil {
                modelDirectory = try? LocalModelManager.directory(for: .weMMEmbedding2B4Bit)
            }
            guard let modelDirectory else { throw CLIError.missing("--model-dir") }
            self.modelDirectory = modelDirectory
            self.videoURL = videoURL
            self.dimension = dimension
            self.framesPerSegment = framesPerSegment
            self.segmentCount = segmentCount
            self.subtitleURL = subtitleURL
            self.queries = queries
        }

        private static func value(_ arguments: [String], _ index: Int) throws -> String {
            guard arguments.indices.contains(index), !arguments[index].isEmpty else {
                throw CLIError.missingValue
            }
            return arguments[index]
        }

        private static func intValue(_ arguments: [String], _ index: Int) throws -> Int {
            guard let value = Int(try value(arguments, index)) else {
                throw CLIError.invalidOptions
            }
            return value
        }
    }

    private enum CLIError: LocalizedError {
        case help
        case missing(String)
        case missingValue
        case unknownArgument(String)
        case invalidOptions

        var errorDescription: String? {
            switch self {
            case .help:
                """
                Usage: VoxStudio --wemm-eval [--model-dir <MLX model>] [options]
                  --model-dir <path>   defaults to the Local Models cache for WeMM Embedding 2B 4-bit
                  --video <path>       MP4 to evaluate
                  --dimension <n>      64, 128, 256, 512, 1024, or 2048 (default: 256)
                  --frames <n>         visual frames per segment (default: 4)
                  --segments <n>       temporal segments to rank (default: 6)
                  --srt <path>        timed subtitles to fuse with each video segment
                  --query <text>       repeatable; uses built-in queries when omitted
                """
            case .missing(let option): "Missing required option \(option)."
            case .missingValue: "Option requires a value."
            case .unknownArgument(let argument): "Unknown argument \(argument)."
            case .invalidOptions: "Invalid evaluation options."
            }
        }
    }

    private struct Segment {
        let start: Double
        let end: Double
        let videoEmbedding: [Float]
        let mixedEmbedding: [Float]
        let subtitleText: String?
    }

    static func run(arguments: [String]) async -> Int {
        do {
            let options = try Options(arguments: arguments)
            try await evaluate(options)
            return 0
        } catch CLIError.help {
            print(CLIError.help.localizedDescription)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("WeMM evaluation failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func evaluate(_ options: Options) async throws {
        guard FileManager.default.fileExists(atPath: options.videoURL.path) else {
            throw NSError(
                domain: "WeMMEmbeddingCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Video not found: \(options.videoURL.path)"])
        }

        print("Loading WeMM MLX model from \(options.modelDirectory.path)…")
        let runtime = try await WeMMEmbeddingRuntime.load(
            from: options.modelDirectory,
            maxFrames: options.framesPerSegment)
        let asset = AVURLAsset(url: options.videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NSError(
                domain: "WeMMEmbeddingCLI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Video has no finite duration."])
        }

        var subtitles: WeMMSubtitleTrack?
        if let subtitleURL = options.subtitleURL {
            guard FileManager.default.fileExists(atPath: subtitleURL.path) else {
                throw NSError(
                    domain: "WeMMEmbeddingCLI",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "SRT not found: \(subtitleURL.path)"])
            }
            let loaded = try await WeMMSubtitleTrack.load(from: subtitleURL)
            subtitles = loaded
            print("Loaded \(loaded.cues.count) subtitle cues from \(subtitleURL.lastPathComponent).")
            print("Mixed mode: one WeMM embedding input containing video plus overlapping subtitle text.\n")
        }

        print("Encoding \(options.segmentCount) temporal segments (dimension \(options.dimension))…")
        let fullVideo = try await runtime.encode(
            videoURL: options.videoURL,
            dimension: options.dimension)
        let fullMixed: [Float]?
        if let subtitles {
            fullMixed = try await runtime.encode(
                videoURL: options.videoURL,
                text: subtitles.fullText,
                dimension: options.dimension)
        } else {
            fullMixed = nil
        }
        var segments: [Segment] = []
        for index in 0 ..< options.segmentCount {
            let start = duration * Double(index) / Double(options.segmentCount)
            let end = duration * Double(index + 1) / Double(options.segmentCount)
            let videoEmbedding = try await runtime.encode(
                videoURL: options.videoURL,
                timeRange: start ... end,
                dimension: options.dimension)
            let subtitleText = subtitles?.text(overlapping: start ... end)
            let mixedEmbedding: [Float]
            if let subtitleText {
                mixedEmbedding = try await runtime.encode(
                    videoURL: options.videoURL,
                    timeRange: start ... end,
                    text: subtitleText,
                    dimension: options.dimension)
            } else {
                mixedEmbedding = videoEmbedding
            }
            segments.append(.init(
                start: start,
                end: end,
                videoEmbedding: videoEmbedding,
                mixedEmbedding: mixedEmbedding,
                subtitleText: subtitleText))
        }

        let queries = options.queries.isEmpty ? Self.defaultQueries : options.queries
        print("\nVideo: \(options.videoURL.lastPathComponent) (\(String(format: "%.2f", duration)) s)")
        print("Full-video embedding ready; ranking segment embeddings:\n")
        for query in queries {
            let queryEmbedding = try await runtime.encode(text: query, dimension: options.dimension)
            let fullScore = WeMMEmbeddingMath.cosine(queryEmbedding, fullVideo)
            let videoRanked = segments.sorted {
                WeMMEmbeddingMath.cosine(queryEmbedding, $0.videoEmbedding)
                    > WeMMEmbeddingMath.cosine(queryEmbedding, $1.videoEmbedding)
            }
            let mixedRanked = segments.sorted {
                WeMMEmbeddingMath.cosine(queryEmbedding, $0.mixedEmbedding)
                    > WeMMEmbeddingMath.cosine(queryEmbedding, $1.mixedEmbedding)
            }

            print("Q: \(query)")
            print("  full video: \(String(format: "%.4f", fullScore))")
            printRanked(
                videoRanked,
                queryEmbedding: queryEmbedding,
                label: "video-only",
                keyPath: \Segment.videoEmbedding)
            if let fullMixed {
                let fullMixedScore = WeMMEmbeddingMath.cosine(queryEmbedding, fullMixed)
                print("  full mixed: \(String(format: "%.4f", fullMixedScore))")
                printRanked(
                    mixedRanked,
                    queryEmbedding: queryEmbedding,
                    label: "mixed",
                    keyPath: \Segment.mixedEmbedding)
            }
            print("")
        }
    }

    private static func printRanked(
        _ ranked: [Segment],
        queryEmbedding: [Float],
        label: String,
        keyPath: KeyPath<Segment, [Float]>
    ) {
        print("  \(label) top:")
        for (rank, segment) in ranked.prefix(3).enumerated() {
            let score = WeMMEmbeddingMath.cosine(queryEmbedding, segment[keyPath: keyPath])
            let subtitleMarker = segment.subtitleText == nil ? "" : "  [srt]"
            print(
                "    \(rank + 1). \(String(format: "%5.2f–%5.2f s", segment.start, segment.end))"
                    + "  score=\(String(format: "%.4f", score))\(subtitleMarker)")
        }
    }

    private static let defaultQueries = [
        "a person describing foot pain and going for treatment",
        "someone says their forehead feels more relaxed",
        "vision becoming brighter and clearer",
        "an interview with an audience in a crowded hall",
        "two women demonstrating how to rotate and gently pull the ears",
        "a woman talking about treatment for herself and her children",
        "a cooking demonstration"
    ]
}

#endif
