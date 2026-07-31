import AppKit
import AVFoundation
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

enum WorkbenchDubLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case english = "en"
    case chinese = "zh"
    case cantonese = "yue"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Auto detect"
        case .english: "English"
        case .chinese: "中文"
        case .cantonese: "粵語"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .russian: "Русский"
        }
    }
}

enum VoiceReferenceGender: String, Codable, CaseIterable, Identifiable, Sendable {
    case female
    case male
    case child

    var id: String { rawValue }

    var label: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        case .child: "Child"
        }
    }
}

struct LocalVoiceReference: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var languageCode: String
    var gender: VoiceReferenceGender
    var transcript: String
    var duration: Double
    var audioFilename: String
    var avatarFilename: String?
    var createdAt = Date()
    var modifiedAt = Date()
    var isDefault = false
}

struct VoiceReferenceDraft: Sendable {
    var name: String
    var languageCode: String
    var gender: VoiceReferenceGender
    var transcript: String
    var sourceAudioURL: URL
    var avatarURL: URL?
}

enum VoiceLibraryError: LocalizedError {
    case missingAudio
    case unsupportedAudio
    case referenceTooShort
    case referenceSilent
    case invalidAvatar
    case avatarTooLarge
    case referenceInUse
    case microphoneDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .missingAudio: "Choose or record a reference audio clip first."
        case .unsupportedAudio: "The selected file does not contain supported audio."
        case .referenceTooShort: "The reference recording must be at least 3 seconds long."
        case .referenceSilent: "The selected reference does not contain enough audible speech."
        case .invalidAvatar: "The avatar must be a valid PNG, JPEG, or WebP image."
        case .avatarTooLarge: "The avatar must be 2 MB or smaller."
        case .referenceInUse: "This voice is used by a dubbing session. Replace its assignments before deleting it."
        case .microphoneDenied: "Microphone access is required to record a reference voice."
        case .recordingFailed: "The microphone recording could not be started."
        }
    }
}

private struct VoiceLibrarySnapshot: Codable, Sendable {
    var schemaVersion = 1
    var references: [LocalVoiceReference]
}

struct PreparedVoiceAudio: Sendable {
    var URL: URL
    var duration: Double
}

private final class VoiceConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

actor VoiceReferenceProcessor {
    static let shared = VoiceReferenceProcessor()

    private let sampleRate = 24_000.0
    private let minimumDuration = 3.0

    func prepare(sourceURL: URL) throws -> PreparedVoiceAudio {
        let input = try AVAudioFile(forReading: sourceURL)
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceLibraryError.unsupportedAudio
        }
        let inputFrameCount = input.length
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(inputFrameCount)
              ) else {
            throw VoiceLibraryError.unsupportedAudio
        }
        try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(inputFrameCount))
        guard inputBuffer.frameLength > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceLibraryError.unsupportedAudio
        }

        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, Int((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 64)
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw VoiceLibraryError.unsupportedAudio
        }
        let conversionInput = VoiceConversionInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, state in
            conversionInput.next(status: state)
        }
        guard conversionError == nil,
              status != .error,
              converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else {
            throw conversionError ?? VoiceLibraryError.unsupportedAudio
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        let duration = Double(samples.count) / sampleRate
        guard duration >= minimumDuration else { throw VoiceLibraryError.referenceTooShort }
        try validateAudibleSpeech(in: samples)

        let outputURL = FileIO.temporaryFileURL(pathExtension: "wav")
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VoiceLibraryError.unsupportedAudio
        }
        outputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                outputBuffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
            }
        }
        let output = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        try output.write(from: outputBuffer)
        return PreparedVoiceAudio(URL: outputURL, duration: duration)
    }

    private func validateAudibleSpeech(in samples: [Float]) throws {
        let windowSize = max(1, Int(sampleRate * 0.02))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / windowSize + 1)
        var cursor = 0
        while cursor < samples.count {
            let end = min(samples.count, cursor + windowSize)
            var sum: Float = 0
            for sample in samples[cursor..<end] { sum += sample * sample }
            levels.append(sqrt(sum / Float(max(1, end - cursor))))
            cursor = end
        }
        guard !levels.isEmpty else { throw VoiceLibraryError.referenceSilent }
        let sorted = levels.sorted()
        let floorIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.1))
        guard let peakLevel = sorted.last, peakLevel >= 0.006 else {
            throw VoiceLibraryError.referenceSilent
        }
        // A percentile-only noise threshold rejects clean clips that contain
        // continuous speech because their "floor" is speech too. Cap the
        // adaptive threshold relative to the clip's peak so both continuous
        // speech and clips with leading/trailing silence remain valid.
        let threshold = max(0.003, min(sorted[floorIndex] * 3, peakLevel * 0.35))
        let requiredWindows = 3
        var consecutive = 0
        for level in levels {
            if level >= threshold {
                consecutive += 1
                if consecutive >= requiredWindows {
                    return
                }
            } else {
                consecutive = 0
            }
        }
        throw VoiceLibraryError.referenceSilent
    }
}

actor VoiceReferenceScriptRecognizer {
    static let shared = VoiceReferenceScriptRecognizer()

    func recognize(
        sourceURL: URL,
        languageCode: String,
        progress: @escaping @Sendable (LocalSpeechProgress) -> Void
    ) async throws -> String {
        let result = try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: sourceURL,
            languageCode: languageCode,
            speakerCount: 1,
            progressUpdate: progress
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalAIError.emptyTranscript }
        return text
    }
}

private actor VoiceLibraryRepository {
    private let directory: URL
    private let manifestURL: URL

    init(directory: URL) {
        self.directory = directory
        manifestURL = directory.appendingPathComponent("library.json")
    }

    func load() -> [LocalVoiceReference] {
        guard let data = try? Data(contentsOf: manifestURL),
              let snapshot = try? JSONDecoder().decode(VoiceLibrarySnapshot.self, from: data) else {
            return []
        }
        return snapshot.references
    }

    func install(
        draft: VoiceReferenceDraft,
        prepared: PreparedVoiceAudio,
        existing: [LocalVoiceReference]
    ) throws -> LocalVoiceReference {
        let id = UUID()
        let voiceDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let audioFilename = "reference.wav"
        let audioURL = voiceDirectory.appendingPathComponent(audioFilename)
        do {
            try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
            try FileIO.copyReplacingDestination(from: prepared.URL, to: audioURL)
            let avatarFilename = try draft.avatarURL.map {
                try installAvatar(sourceURL: $0, voiceDirectory: voiceDirectory)
            }
            let language = Self.normalizedLanguage(draft.languageCode)
            var reference = LocalVoiceReference(
                id: id,
                name: Self.normalizedName(draft.name),
                languageCode: language,
                gender: draft.gender,
                transcript: draft.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: prepared.duration,
                audioFilename: audioFilename,
                avatarFilename: avatarFilename,
                isDefault: !existing.contains { $0.languageCode == language && $0.isDefault }
            )
            reference.modifiedAt = reference.createdAt
            try save(existing + [reference])
            try? FileManager.default.removeItem(at: prepared.URL)
            return reference
        } catch {
            try? FileManager.default.removeItem(at: voiceDirectory)
            try? FileManager.default.removeItem(at: prepared.URL)
            throw error
        }
    }

    func update(
        id: UUID,
        name: String,
        languageCode: String,
        gender: VoiceReferenceGender,
        transcript: String,
        avatarURL: URL?,
        clearAvatar: Bool,
        existing: [LocalVoiceReference]
    ) throws -> [LocalVoiceReference] {
        guard let index = existing.firstIndex(where: { $0.id == id }) else { return existing }
        var next = existing
        let oldLanguage = next[index].languageCode
        let newLanguage = Self.normalizedLanguage(languageCode)
        next[index].name = Self.normalizedName(name)
        next[index].languageCode = newLanguage
        next[index].gender = gender
        next[index].transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        next[index].modifiedAt = Date()
        let voiceDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if clearAvatar, let filename = next[index].avatarFilename {
            try? FileManager.default.removeItem(at: voiceDirectory.appendingPathComponent(filename))
            next[index].avatarFilename = nil
        }
        if let avatarURL {
            next[index].avatarFilename = try installAvatar(
                sourceURL: avatarURL,
                voiceDirectory: voiceDirectory
            )
        }
        if next[index].isDefault, oldLanguage != newLanguage {
            next[index].isDefault = !next.contains {
                $0.id != id && $0.languageCode == newLanguage && $0.isDefault
            }
        }
        try save(next)
        return next
    }

    func setDefault(
        id: UUID,
        existing: [LocalVoiceReference]
    ) throws -> [LocalVoiceReference] {
        guard let selected = existing.first(where: { $0.id == id }) else { return existing }
        let now = Date()
        let next = existing.map { item -> LocalVoiceReference in
            var updated = item
            if item.languageCode == selected.languageCode {
                updated.isDefault = item.id == id
                if updated.isDefault != item.isDefault { updated.modifiedAt = now }
            }
            return updated
        }
        try save(next)
        return next
    }

    func delete(id: UUID, existing: [LocalVoiceReference]) throws -> [LocalVoiceReference] {
        guard let removed = existing.first(where: { $0.id == id }) else { return existing }
        var next = existing.filter { $0.id != id }
        if removed.isDefault,
           let replacementIndex = next.indices.first(where: { next[$0].languageCode == removed.languageCode }) {
            next[replacementIndex].isDefault = true
            next[replacementIndex].modifiedAt = Date()
        }
        try save(next)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(id.uuidString, isDirectory: true)
        )
        return next
    }

    private func save(_ references: [LocalVoiceReference]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(VoiceLibrarySnapshot(references: references))
        try data.write(to: manifestURL, options: .atomic)
    }

    private func installAvatar(sourceURL: URL, voiceDirectory: URL) throws -> String {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > 2 * 1024 * 1024 {
            throw VoiceLibraryError.avatarTooLarge
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type as String),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            throw VoiceLibraryError.invalidAvatar
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw VoiceLibraryError.invalidAvatar
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw VoiceLibraryError.invalidAvatar }
        let filename = "avatar.png"
        try FileIO.writeData(data as Data, to: voiceDirectory.appendingPathComponent(filename))
        return filename
    }

    private static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Reference Voice" : trimmed
    }

    private static func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "en" : trimmed
    }
}

@Observable
@MainActor
final class VoiceLibraryStore {
    static let shared = VoiceLibraryStore()

    var references: [LocalVoiceReference] = []
    var isLoading = true
    var errorMessage: String?
    var playingID: UUID?

    private let directory: URL
    private let repository: VoiceLibraryRepository
    private var audioPlayer: AVAudioPlayer?
    private var playbackCompletionTask: Task<Void, Never>?

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio/VoiceLibrary", isDirectory: true)
        repository = VoiceLibraryRepository(directory: directory)
        Task { await load() }
    }

    func create(_ draft: VoiceReferenceDraft) async throws -> LocalVoiceReference {
        errorMessage = nil
        let prepared = try await VoiceReferenceProcessor.shared.prepare(sourceURL: draft.sourceAudioURL)
        let reference = try await repository.install(
            draft: draft,
            prepared: prepared,
            existing: references
        )
        references.append(reference)
        references.sort { $0.createdAt > $1.createdAt }
        return reference
    }

    func update(
        id: UUID,
        name: String,
        languageCode: String,
        gender: VoiceReferenceGender,
        transcript: String,
        avatarURL: URL? = nil,
        clearAvatar: Bool = false
    ) async throws {
        references = try await repository.update(
            id: id,
            name: name,
            languageCode: languageCode,
            gender: gender,
            transcript: transcript,
            avatarURL: avatarURL,
            clearAvatar: clearAvatar,
            existing: references
        )
    }

    func setDefault(_ id: UUID) async throws {
        references = try await repository.setDefault(id: id, existing: references)
    }

    func delete(_ id: UUID) async throws {
        guard !WorkbenchStore.shared.isVoiceReferenceInUse(id) else {
            throw VoiceLibraryError.referenceInUse
        }
        stopPlayback()
        references = try await repository.delete(id: id, existing: references)
    }

    func reference(id: UUID?) -> LocalVoiceReference? {
        guard let id else { return nil }
        return references.first { $0.id == id }
    }

    func defaultReference(languageCode: String) -> LocalVoiceReference? {
        let base = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? languageCode
        return references.first {
            $0.isDefault && ($0.languageCode.lowercased().split(separator: "-").first.map(String.init) ?? $0.languageCode) == base
        }
    }

    func compatibleReferences(
        languageCode: String,
        including selectedID: UUID? = nil
    ) -> [LocalVoiceReference] {
        guard languageCode != WorkbenchDubLanguage.automatic.rawValue else { return references }
        let base = languageCode.lowercased().split(separator: "-").first
        return references.filter { reference in
            reference.id == selectedID
                || reference.languageCode.lowercased().split(separator: "-").first == base
        }
    }

    func audioURL(for reference: LocalVoiceReference) -> URL {
        directory
            .appendingPathComponent(reference.id.uuidString, isDirectory: true)
            .appendingPathComponent(reference.audioFilename)
    }

    func avatarURL(for reference: LocalVoiceReference) -> URL? {
        guard let avatarFilename = reference.avatarFilename else { return nil }
        return directory
            .appendingPathComponent(reference.id.uuidString, isDirectory: true)
            .appendingPathComponent(avatarFilename)
    }

    func dubReference(for id: UUID?) -> DubVoiceReference? {
        guard let reference = reference(id: id) else { return nil }
        return DubVoiceReference(
            audioURL: audioURL(for: reference),
            transcript: reference.transcript
        )
    }

    func togglePlayback(_ reference: LocalVoiceReference) {
        if playingID == reference.id {
            stopPlayback()
            return
        }
        do {
            stopPlayback()
            errorMessage = nil
            let player = try AVAudioPlayer(contentsOf: audioURL(for: reference))
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingID = reference.id
            playbackCompletionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                guard !Task.isCancelled, self?.audioPlayer === player else { return }
                self?.stopPlayback()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    private func load() async {
        references = await repository.load().sorted { $0.createdAt > $1.createdAt }
        isLoading = false
    }
}

private actor VoiceReferenceRecorder {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func start() async throws -> URL {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard granted else { throw VoiceLibraryError.microphoneDenied }
        let URL = FileIO.temporaryFileURL(pathExtension: "wav")
        let recorder = try AVAudioRecorder(url: URL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else { throw VoiceLibraryError.recordingFailed }
        self.recorder = recorder
        outputURL = URL
        return URL
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { outputURL = nil }
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}

@Observable
@MainActor
final class VoiceRecorderController {
    var isRecording = false
    var duration = 0.0
    var recordedURL: URL?
    var errorMessage: String?

    private let recorder = VoiceReferenceRecorder()
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        Task {
            do {
                recordedURL = try await recorder.start()
                startedAt = Date()
                duration = 0
                isRecording = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        timerTask?.cancel()
        timerTask = nil
        Task {
            recordedURL = await recorder.stop()
            isRecording = false
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        Task { await recorder.cancel() }
        isRecording = false
        duration = 0
        recordedURL = nil
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt else { return }
                duration = Date().timeIntervalSince(startedAt)
            }
        }
    }
}
