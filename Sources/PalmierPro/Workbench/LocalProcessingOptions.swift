import Foundation

/// Upload-transcribe options aligned with voxella-web `ProcessingOptions`.
struct LocalProcessingOptions: Equatable, Sendable {
    var languageCode: String?
    /// Optional user title for a single-file import; blank means auto-generate after transcription.
    var customTitle: String?
    var speakerCount: SpeakerCountOption = .auto
    var enableTranslation = false
    var targetLanguageCode: String?
    var clipStartMs: Int?
    var clipEndMs: Int?

    var normalizedTargetLanguageCode: String? {
        guard enableTranslation else { return nil }
        let trimmed = targetLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var clipRangeSeconds: ClosedRange<Double>? {
        guard let startMs = clipStartMs, let endMs = clipEndMs, endMs > startMs else { return nil }
        return Double(startMs) / 1000 ... Double(endMs) / 1000
    }
}

struct TranscriptionBatchState: Identifiable, Equatable, Sendable {
    var id = UUID()
    var jobIDs: [UUID]
    var startedAt = Date()
}

enum LocalTranscriptionResourcePolicy {
    /// Cap concurrent local ASR/media-flow jobs. MLX inference is already gated at 1;
    /// keep the workbench queue at 1 so decode/VAD/align never pile up.
    static let maxConcurrentJobs = 1
    static let maxFilesPerBatch = 20
    static let maxBytesPerFile: UInt64 = 4 * 1024 * 1024 * 1024
    static let pauseBetweenJobs: Duration = .milliseconds(350)

    enum AdmissionError: LocalizedError {
        case emptySelection
        case tooManyFiles(limit: Int)
        case fileTooLarge(name: String, limitBytes: UInt64)
        case missingFile(name: String)
        case thermalPressure

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Choose at least one media file."
            case .tooManyFiles(let limit):
                return "Select at most \(limit) files at a time so local models stay responsive."
            case .fileTooLarge(let name, let limitBytes):
                let gb = Double(limitBytes) / (1024 * 1024 * 1024)
                return "“\(name)” exceeds the \(gb.formatted(.number.precision(.fractionLength(0)))) GB local processing limit."
            case .missingFile(let name):
                return "“\(name)” could not be opened."
            case .thermalPressure:
                return "This Mac is under thermal pressure. Wait a moment, then try again with fewer or shorter files."
            }
        }
    }

    static func admit(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw AdmissionError.emptySelection }
        guard urls.count <= maxFilesPerBatch else {
            throw AdmissionError.tooManyFiles(limit: maxFilesPerBatch)
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            throw AdmissionError.thermalPressure
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw AdmissionError.missingFile(name: url.lastPathComponent)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, UInt64(size) > maxBytesPerFile {
                throw AdmissionError.fileTooLarge(name: url.lastPathComponent, limitBytes: maxBytesPerFile)
            }
        }
    }

    static var shouldDelayBeforeNextJob: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }

    static var interJobDelay: Duration {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: .seconds(2)
        case .serious: .seconds(1)
        default: pauseBetweenJobs
        }
    }
}
