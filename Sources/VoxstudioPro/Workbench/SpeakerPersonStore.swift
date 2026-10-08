import AVFoundation
import CryptoKit
import Foundation
import Observation

/// A known person whose voice can name anonymous speakers across projects.
/// Several reference voices, in any language or from any device, may belong
/// to one person; matching ignores the dubbing language filter.
struct SpeakerPerson: Codable, Identifiable, Equatable, Sendable {
    enum VoiceprintState: String, Codable, Sendable {
        case notPrepared
        case preparing
        case ready
        /// Segments disagree; the references may contain another person.
        case needsReview
        /// Less than the minimum single-speaker speech across references.
        case insufficientAudio
        /// The front end changed and no source audio is left to rebuild from.
        case needsSamples
        case failed
    }

    var id = UUID()
    var name: String
    var referenceIDs: [UUID] = []
    var voiceprint: SpeakerVoiceprint?
    var voiceprintState: VoiceprintState = .notPrepared
    var voiceprintMessage: String?
    var createdAt = Date()
    var modifiedAt = Date()

    var canMatch: Bool {
        guard let voiceprint, voiceprint.version == SpeakerEmbeddingService.version else { return false }
        return voiceprintState == .ready || voiceprintState == .needsReview
    }
}

/// Segment embeddings of one reference audio file, rebuilt when the audio or
/// the embedding version changes.
struct ReferenceVoiceprintRecord: Codable, Equatable, Sendable {
    var audioDigest: String
    var version: String
    var segments: [VoiceprintSegment]
    var speechDuration: Double { segments.reduce(0) { $0 + $1.duration } }
}

private struct SpeakerPersonSnapshot: Codable {
    var schemaVersion = 1
    var persons: [SpeakerPerson]
    var referencePrints: [String: ReferenceVoiceprintRecord]
}

@Observable
@MainActor
final class SpeakerPersonStore {
    static let shared = SpeakerPersonStore()

    private(set) var persons: [SpeakerPerson] = []
    private(set) var isLoading = true
    var errorMessage: String?

    private var referencePrints: [UUID: ReferenceVoiceprintRecord] = [:]
    private var preparation: [UUID: Task<Void, Never>] = [:]
    private let manifestURL: URL

    private init() {
        manifestURL = AppSupportPaths.applicationSupport()
            .appendingPathComponent("VoiceLibrary", isDirectory: true)
            .appendingPathComponent("persons.json")
        Task { await load() }
    }

    // MARK: - Queries

    func person(id: UUID?) -> SpeakerPerson? {
        guard let id else { return nil }
        return persons.first { $0.id == id }
    }

    func person(forReference referenceID: UUID) -> SpeakerPerson? {
        persons.first { $0.referenceIDs.contains(referenceID) }
    }

    func person(named name: String) -> SpeakerPerson? {
        let key = Self.normalizedName(name).lowercased()
        return persons.first { $0.name.lowercased() == key }
    }

    var sortedPersons: [SpeakerPerson] {
        persons.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Ready voiceprints for the selected candidates.
    func candidates(_ ids: [UUID]) -> [SpeakerMatchCandidate] {
        ids.compactMap { id in
            guard let person = person(id: id), person.canMatch, let voiceprint = person.voiceprint else { return nil }
            return SpeakerMatchCandidate(personID: person.id, name: person.name, voiceprint: voiceprint)
        }
    }

    /// Identity cache component: changes when a candidate's voiceprint changes.
    func candidateDigest(_ ids: [UUID]) -> String {
        let parts = ids.sorted { $0.uuidString < $1.uuidString }.map { id -> String in
            guard let person = person(id: id), let print = person.voiceprint else { return "\(id.uuidString):none" }
            let data = print.vector.withUnsafeBufferPointer { Data(buffer: $0) }
            let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            return "\(id.uuidString):\(print.version):\(hash)"
        }
        return parts.joined(separator: ",")
    }

    // MARK: - Editing

    @discardableResult
    func createPerson(name: String, referenceIDs: [UUID] = []) -> SpeakerPerson {
        var person = SpeakerPerson(name: Self.normalizedName(name))
        persons.append(person)
        for referenceID in referenceIDs { attach(referenceID, to: person.id) }
        person = self.person(id: person.id) ?? person
        save()
        if !person.referenceIDs.isEmpty { prepareVoiceprint(person.id) }
        return person
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = persons.firstIndex(where: { $0.id == id }) else { return }
        persons[index].name = Self.normalizedName(name)
        persons[index].modifiedAt = Date()
        save()
    }

    /// Deleting a person keeps its reference voices and historical names in sessions.
    func deletePerson(_ id: UUID) {
        preparation.removeValue(forKey: id)?.cancel()
        persons.removeAll { $0.id == id }
        save()
    }

    /// Links a reference to at most one person, then rebuilds affected voiceprints.
    func link(reference referenceID: UUID, to personID: UUID?) {
        let previous = person(forReference: referenceID)?.id
        guard previous != personID else { return }
        if let personID { attach(referenceID, to: personID) } else { detach(referenceID) }
        save()
        for id in Set([previous, personID].compactMap { $0 }) { prepareVoiceprint(id) }
    }

    /// Removing a reference keeps the person and recomputes from what remains.
    func referenceDeleted(_ referenceID: UUID) {
        let owner = person(forReference: referenceID)?.id
        detach(referenceID)
        referencePrints[referenceID] = nil
        save()
        if let owner { prepareVoiceprint(owner) }
    }

    private func attach(_ referenceID: UUID, to personID: UUID) {
        detach(referenceID)
        guard let index = persons.firstIndex(where: { $0.id == personID }) else { return }
        persons[index].referenceIDs.append(referenceID)
        persons[index].modifiedAt = Date()
    }

    private func detach(_ referenceID: UUID) {
        for index in persons.indices where persons[index].referenceIDs.contains(referenceID) {
            persons[index].referenceIDs.removeAll { $0 == referenceID }
            persons[index].modifiedAt = Date()
        }
    }

    // MARK: - Voiceprints

    func isPreparing(_ id: UUID) -> Bool { preparation[id] != nil }

    /// Re-extracts reference embeddings that are missing or stale and
    /// aggregates them by effective speech duration.
    func prepareVoiceprint(_ id: UUID, force: Bool = false) {
        guard person(id: id) != nil else { return }
        preparation[id]?.cancel()
        update(id) {
            $0.voiceprintState = .preparing
            $0.voiceprintMessage = nil
        }
        preparation[id] = Task { [weak self] in
            await self?.buildVoiceprint(id, force: force)
            self?.preparation[id] = nil
        }
    }

    func waitForPreparation(_ ids: [UUID]) async {
        for id in ids { await preparation[id]?.value }
    }

    private func buildVoiceprint(_ id: UUID, force: Bool) async {
        guard let person = person(id: id) else { return }
        let library = VoiceLibraryStore.shared
        let version = SpeakerEmbeddingService.version
        var segments: [VoiceprintSegment] = []
        var missingAudio = false
        do {
            for referenceID in person.referenceIDs {
                try Task.checkCancellation()
                guard let reference = library.reference(id: referenceID) else { continue }
                let url = library.audioURL(for: reference)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missingAudio = true
                    continue
                }
                let digest = try await Self.digest(of: url)
                if !force, let record = referencePrints[referenceID],
                   record.audioDigest == digest, record.version == version {
                    segments += record.segments
                    continue
                }
                let windows = try await SpeakerEnrollmentAudio.speechWindows(url: url)
                let embedded = try await SpeakerEmbeddingService.shared.segments(url: url, windows: windows)
                referencePrints[referenceID] = ReferenceVoiceprintRecord(
                    audioDigest: digest, version: version, segments: embedded
                )
                segments += embedded
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            update(id) {
                $0.voiceprintState = .failed
                $0.voiceprintMessage = error.localizedDescription
            }
            save()
            return
        }

        let voiceprint = SpeakerVoiceprintPolicy.aggregate(
            segments, version: version, minimumDuration: SpeakerVoiceprintPolicy.minimumEnrollmentDuration
        )
        update(id) { person in
            person.voiceprint = voiceprint
            if let voiceprint {
                person.voiceprintState = voiceprint.quality == .needsReview ? .needsReview : .ready
                person.voiceprintMessage = nil
            } else if segments.isEmpty, missingAudio {
                person.voiceprintState = .needsSamples
            } else {
                person.voiceprintState = person.referenceIDs.isEmpty && !missingAudio ? .notPrepared : .insufficientAudio
            }
        }
        save()
    }

    private func update(_ id: UUID, _ transform: (inout SpeakerPerson) -> Void) {
        guard let index = persons.firstIndex(where: { $0.id == id }) else { return }
        transform(&persons[index])
    }

    // MARK: - Persistence

    private func load() async {
        let url = manifestURL
        let snapshot = await Task.detached(priority: .utility) { () -> SpeakerPersonSnapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SpeakerPersonSnapshot.self, from: data)
        }.value
        persons = snapshot?.persons ?? []
        referencePrints = Dictionary(uniqueKeysWithValues: (snapshot?.referencePrints ?? [:]).compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        isLoading = false
        migrateStaleVoiceprints()
    }

    /// Voiceprints from an older front end are rebuilt from their source audio;
    /// without source audio the person is marked as needing new samples.
    private func migrateStaleVoiceprints() {
        let version = SpeakerEmbeddingService.version
        for index in persons.indices {
            if persons[index].voiceprintState == .preparing { persons[index].voiceprintState = .notPrepared }
            let stale = persons[index].voiceprint.map { $0.version != version } ?? false
            guard stale, !persons[index].referenceIDs.isEmpty else {
                if stale { persons[index].voiceprintState = .needsSamples }
                continue
            }
            prepareVoiceprint(persons[index].id)
        }
    }

    private func save() {
        let snapshot = SpeakerPersonSnapshot(
            persons: persons.map { person in
                var copy = person
                if copy.voiceprintState == .preparing { copy.voiceprintState = .notPrepared }
                return copy
            },
            referencePrints: Dictionary(uniqueKeysWithValues: referencePrints.map { ($0.key.uuidString, $0.value) })
        )
        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: manifestURL, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed person" : trimmed
    }

    private static func digest(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Speech stretches of a clean enrollment recording, split into embedding windows.
enum SpeakerEnrollmentAudio {
    static let frameDuration = 0.03
    static let silenceGap = 0.3
    static let relativeFloorDB: Float = -35

    static func speechWindows(url: URL) async throws -> [SpeechTimeRange] {
        let samples = try await AudioTrackReader.readMonoFloats(
            from: url, sampleRate: Double(SpeakerEmbeddingService.sampleRate), range: nil
        )
        return SpeakerVoiceprintPolicy.windows(
            for: speechRanges(samples: samples, sampleRate: Double(SpeakerEmbeddingService.sampleRate))
        )
    }

    /// Energy-based speech ranges; enrollment audio is short and clean, so a
    /// relative RMS floor with short-gap bridging is sufficient.
    static func speechRanges(samples: [Float], sampleRate: Double) -> [SpeechTimeRange] {
        let frame = max(1, Int(frameDuration * sampleRate))
        guard samples.count >= frame else { return [] }
        let rms: [Float] = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for index in start..<(start + frame) { sum += samples[index] * samples[index] }
            return (sum / Float(frame)).squareRoot()
        }
        guard let peak = rms.max(), peak > 1e-4 else { return [] }
        let floor = max(peak * powf(10, relativeFloorDB / 20), 1e-4)
        var ranges: [SpeechTimeRange] = []
        var start: Int?
        var lastVoiced = 0
        let gapFrames = Int(silenceGap / frameDuration)
        for (index, value) in rms.enumerated() {
            if value >= floor {
                if start == nil { start = index }
                lastVoiced = index
            } else if let open = start, index - lastVoiced > gapFrames {
                ranges.append(SpeechTimeRange(start: Double(open) * frameDuration, end: Double(lastVoiced + 1) * frameDuration))
                start = nil
            }
        }
        if let open = start {
            ranges.append(SpeechTimeRange(start: Double(open) * frameDuration, end: Double(lastVoiced + 1) * frameDuration))
        }
        return ranges
    }
}
