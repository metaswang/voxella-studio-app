import AppKit
import AVFoundation
import CryptoKit
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

    static func detected(from languageCode: String?) -> Self? {
        guard let code = ASREngineLanguagePolicy.normalizedISO(languageCode),
              let language = Self(rawValue: code),
              language != .automatic else {
            return nil
        }
        return language
    }

    func resolvedCode(detectedLanguageCode: String?) -> String {
        guard self == .automatic else { return rawValue }
        return ASREngineLanguagePolicy.normalizedISO(detectedLanguageCode) ?? rawValue
    }

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
    /// Cloud metadata is optional so older workbench voice manifests remain valid.
    var cloudReferenceID: UUID?
    var cloudObjectKey: String?
    var cloudFingerprint: String?
}

struct VoiceReferenceDraft: Sendable {
    var name: String
    var languageCode: String
    var gender: VoiceReferenceGender
    var transcript: String
    var sourceAudioURL: URL
    var avatarURL: URL?
    var source: VoiceReferenceAudioSource = .importedFile
    var usesRecognizedPrefix = false
}

enum VoiceReferenceAudioSource: Equatable, Sendable {
    case importedFile
    case microphoneRecording
}

enum VoiceLibraryError: LocalizedError, Sendable {
    case missingAudio
    case unsupportedAudio
    case referenceTooShort
    case referenceSilent
    case invalidAvatar
    case avatarTooLarge
    case referenceInUse
    case microphoneDenied
    case microphoneRestricted
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
        case .microphoneDenied: "Microphone access is denied. Allow it in System Settings → Privacy & Security → Microphone, then retry."
        case .microphoneRestricted: "Microphone access is restricted by macOS or device management."
        case .recordingFailed: "The microphone recording could not be started."
        }
    }

    var requiresMicrophonePermissionSettings: Bool {
        switch self {
        case .microphoneDenied, .microphoneRestricted:
            true
        default:
            false
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

final class VoiceConversionInput: @unchecked Sendable {
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

    func prepare(
        sourceURL: URL,
        trimBoundarySilence: Bool = false,
        usesRecognizedPrefix: Bool = false
    ) async throws -> PreparedVoiceAudio {
        var samples = usesRecognizedPrefix
            ? try await SpeechInputAudio.samples(from: sourceURL, sampleRate: Int(sampleRate))
            : try convertedSamples(from: sourceURL)
        try Task.checkCancellation()
        if trimBoundarySilence {
            let processed = try await VoiceReferenceCapturePipeline.process(
                samples: samples,
                sampleRate: sampleRate
            )
            samples = processed.samples
            if processed.confirmedNoSpeech {
                throw VoiceLibraryError.referenceSilent
            }
        }
        try Task.checkCancellation()
        let duration = Double(samples.count) / sampleRate
        guard duration >= minimumDuration else { throw VoiceLibraryError.referenceTooShort }
        try validateAudibleSpeech(in: samples)

        let outputURL = FileIO.temporaryFileURL(pathExtension: "wav")
        do {
            try Self.writePCM16WAV(samples: samples, sampleRate: sampleRate, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return PreparedVoiceAudio(URL: outputURL, duration: duration)
    }

    private func convertedSamples(from sourceURL: URL) throws -> [Float] {
        let input = try AVAudioFile(forReading: sourceURL)
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceLibraryError.unsupportedAudio
        }
        let inputFrameCount = input.length
        guard inputFrameCount > 0, inputFrameCount < Int64(UInt32.max) else {
            throw VoiceLibraryError.unsupportedAudio
        }
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
        let capacity = (Double(inputBuffer.frameLength) * ratio).rounded(.up) + 64
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max) else {
            throw VoiceLibraryError.unsupportedAudio
        }
        let outputCapacity = AVAudioFrameCount(capacity)
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

        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    private static func writePCM16WAV(
        samples: [Float],
        sampleRate: Double,
        to outputURL: URL
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.int16ChannelData?[0] else {
            throw VoiceLibraryError.unsupportedAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            let normalized = sample.isFinite ? min(max(sample, -1), 1) : 0
            channel[index] = Int16((normalized * Float(Int16.max)).rounded())
        }
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try output.write(from: buffer)
    }

    private func validateAudibleSpeech(in samples: [Float]) throws {
        guard VoiceReferenceSilenceTrimmer.hasAudibleSpeech(
            samples: samples,
            sampleRate: sampleRate
        ) else {
            throw VoiceLibraryError.referenceSilent
        }
    }
}

enum VoiceReferenceSilenceTrimmer {
    static let analysisWindowDuration = AudioBoundarySilenceTrimmer.analysisWindowDuration
    static let minimumAudibleDuration = AudioBoundarySilenceTrimmer.minimumAudibleDuration
    static let boundaryPadding = AudioBoundarySilenceTrimmer.boundaryPadding

    static func trim(
        samples: [Float],
        sampleRate: Double,
        padding: Double = boundaryPadding
    ) -> [Float] {
        AudioBoundarySilenceTrimmer.trim(samples: samples, sampleRate: sampleRate, padding: padding)
    }

    static func hasAudibleSpeech(samples: [Float], sampleRate: Double) -> Bool {
        AudioBoundarySilenceTrimmer.hasAudibleSpeech(samples: samples, sampleRate: sampleRate)
    }

    /// Contiguous sample range covering sustained audible energy, without boundary padding.
    static func audibleSpan(
        samples: [Float],
        sampleRate: Double
    ) -> Range<Int>? {
        AudioBoundarySilenceTrimmer.audibleSpan(samples: samples, sampleRate: sampleRate)
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

    func setCloudReference(
        id: UUID,
        remoteID: UUID,
        objectKey: String,
        fingerprint: String,
        existing: [LocalVoiceReference]
    ) throws -> [LocalVoiceReference] {
        guard let index = existing.firstIndex(where: { $0.id == id }) else { return existing }
        var next = existing
        next[index].cloudReferenceID = remoteID
        next[index].cloudObjectKey = objectKey
        next[index].cloudFingerprint = fingerprint
        next[index].modifiedAt = Date()
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
        directory = AppSupportPaths.applicationSupport()
            .appendingPathComponent("VoiceLibrary", isDirectory: true)
        repository = VoiceLibraryRepository(directory: directory)
        Task { await load() }
    }

    func create(_ draft: VoiceReferenceDraft) async throws -> LocalVoiceReference {
        errorMessage = nil
        let prepared = try await VoiceReferenceProcessor.shared.prepare(
            sourceURL: draft.sourceAudioURL,
            trimBoundarySilence: draft.source == .microphoneRecording,
            usesRecognizedPrefix: draft.usesRecognizedPrefix
        )
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
        SpeakerPersonStore.shared.referenceDeleted(id)
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
            transcript: reference.transcript,
            name: reference.name
        )
    }

    func ensureCloudReference(
        _ id: UUID,
        client: VoxellaAPIClient = .shared
    ) async throws -> LocalVoiceReference {
        guard let reference = reference(id: id) else { throw VoiceLibraryError.missingAudio }
        let audioURL = self.audioURL(for: reference)
        let fingerprint = try await Self.cloudFingerprint(
            audioURL: audioURL,
            languageCode: reference.languageCode,
            gender: reference.gender.rawValue,
            transcript: reference.transcript
        )
        if reference.cloudReferenceID != nil,
           reference.cloudObjectKey != nil,
           reference.cloudFingerprint == fingerprint {
            return reference
        }
        let prepared = try await VoiceReferenceProcessor.shared.prepare(sourceURL: audioURL)
        let uploaded: VoxellaDubReferenceAudio
        do {
            uploaded = try await client.uploadDubReferenceAudio(
                fileURL: prepared.URL,
                name: reference.name,
                languageCode: reference.languageCode,
                gender: reference.gender.rawValue,
                transcript: reference.transcript
            )
        } catch {
            await Self.removeTemporaryFile(at: prepared.URL)
            throw error
        }
        await Self.removeTemporaryFile(at: prepared.URL)
        guard let current = self.reference(id: id) else { throw VoiceLibraryError.missingAudio }
        references = try await repository.setCloudReference(
            id: id,
            remoteID: uploaded.id,
            objectKey: uploaded.r2ObjectKey,
            fingerprint: fingerprint,
            existing: references
        )
        return references.first { $0.id == id } ?? current
    }

    private static func removeTemporaryFile(at URL: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: URL)
        }.value
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
            AudioPlaybackCoordinator.shared.begin(id: Self.playbackID(reference.id)) { [weak self] in
                self?.stopPlayback()
            }
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
        if let playingID {
            AudioPlaybackCoordinator.shared.end(id: Self.playbackID(playingID))
        }
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    private static func playbackID(_ id: UUID) -> String {
        "voice-reference:\(id.uuidString)"
    }

    private static func cloudFingerprint(
        audioURL: URL,
        languageCode: String,
        gender: String,
        transcript: String
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let audio = try Data(contentsOf: audioURL)
            var data = Data("\(languageCode)\n\(gender)\n\(transcript)\n".utf8)
            data.append(audio)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func load() async {
        references = await repository.load().sorted { $0.createdAt > $1.createdAt }
        isLoading = false
    }
}
