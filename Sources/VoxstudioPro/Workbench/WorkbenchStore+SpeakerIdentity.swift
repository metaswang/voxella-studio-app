import AVFoundation
import Foundation
import Observation

/// One anonymous speaker of a session and the person it resolved to.
struct SessionSpeakerIdentity: Codable, Equatable, Identifiable, Sendable {
    /// Label assigned by diarization, e.g. "Speaker 2". Stable for the transcript.
    var anonymousLabel: String
    /// Label currently shown in words, cues and exports.
    var displayLabel: String
    var personID: UUID?
    /// Name at the time of linking; kept when the person is renamed or deleted.
    var nameSnapshot: String?
    var status: SpeakerMatchStatus
    var score: Double?
    var margin: Double?
    var updatedAt = Date()

    var id: String { anonymousLabel }
    var isManual: Bool { status == .manual }
}

struct SessionSpeakerIdentities: Codable, Equatable, Sendable {
    var entries: [SessionSpeakerIdentity] = []
    /// Embedding version, calibration, candidate voiceprints and evidence.
    /// Unchanged keys skip matching; diarization is never rerun for identity.
    var matchKey: String?
    var lastMatchError: String?

    func entry(displayLabel label: String) -> SessionSpeakerIdentity? {
        entries.first { $0.displayLabel == label }
    }
}

/// Transient per-session identity work, for progress and retry UI.
@Observable
@MainActor
final class SpeakerIdentityActivity {
    static let shared = SpeakerIdentityActivity()
    enum Phase: Equatable {
        case preparing
        case matching
        case savingVoice
    }
    private(set) var phases: [UUID: Phase] = [:]
    fileprivate var tasks: [UUID: Task<Void, Never>] = [:]

    func phase(for id: UUID) -> Phase? { phases[id] }
    fileprivate func set(_ phase: Phase?, for id: UUID) { phases[id] = phase }
}

enum SessionSpeakerVoiceError: LocalizedError {
    case noSession
    case notEnoughSpeech(Double)
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .noSession:
            "This session is no longer available."
        case .notEnoughSpeech(let seconds):
            "Only \(String(format: "%.1f", seconds)) s of clear speech from this speaker was found. At least 3 s is needed."
        case .audioUnavailable:
            "The session audio could not be read."
        }
    }
}

extension WorkbenchStore {
    // MARK: - Automatic matching

    /// Names anonymous speakers from the session's candidate people. Manual
    /// links always win; unchanged inputs are skipped.
    func matchSessionSpeakers(_ id: UUID, force: Bool = false) {
        guard let job = transcriptions.first(where: { $0.id == id }),
              job.compute == .local, job.speakerCount.count != 0, job.speakerCount.count != 1,
              !job.candidatePersonIDs.isEmpty, job.result != nil else { return }
        let activity = SpeakerIdentityActivity.shared
        activity.tasks[id]?.cancel()
        activity.set(.preparing, for: id)
        activity.tasks[id] = Task { [weak self] in
            defer {
                activity.set(nil, for: id)
                activity.tasks[id] = nil
            }
            await self?.performSpeakerMatching(id, force: force)
        }
    }

    private func performSpeakerMatching(_ id: UUID, force: Bool) async {
        guard let job = transcriptions.first(where: { $0.id == id }), let result = job.result else { return }
        let people = SpeakerPersonStore.shared
        await people.waitForPreparation(job.candidatePersonIDs)
        let evidence = Self.speakerEvidence(for: job, result: result)
        let candidates = people.candidates(job.candidatePersonIDs)
        let key = [
            SpeakerEmbeddingService.version,
            SpeakerMatchCalibration.current.version,
            people.candidateDigest(job.candidatePersonIDs),
            Self.evidenceDigest(evidence),
        ].joined(separator: "|")
        if !force, job.speakerIdentities?.matchKey == key { return }

        var identities = job.speakerIdentities ?? SessionSpeakerIdentities()
        for item in evidence where !identities.entries.contains(where: { $0.anonymousLabel == item.label }) {
            identities.entries.append(.init(anonymousLabel: item.label, displayLabel: item.label, status: .unknown))
        }
        guard !candidates.isEmpty else {
            identities.matchKey = key
            identities.lastMatchError = nil
            updateTranscription(id) { $0.speakerIdentities = identities }
            return
        }

        SpeakerIdentityActivity.shared.set(.matching, for: id)
        let audioURL = job.sourceURL
        var channels: [SpeakerChannelProfile] = []
        do {
            for item in evidence {
                try Task.checkCancellation()
                guard identities.entries.first(where: { $0.anonymousLabel == item.label })?.isManual != true else { continue }
                let windows = SpeakerVoiceprintPolicy.windows(for: item.cleanRanges)
                let segments = try await SpeakerEmbeddingService.shared.segments(url: audioURL, windows: windows)
                channels.append(SpeakerChannelProfile(
                    label: item.label,
                    voiceprint: SpeakerVoiceprintPolicy.aggregate(segments, version: SpeakerEmbeddingService.version),
                    overlapsWith: Set(item.overlapsWith)
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            // Text and timestamps stay; identity can be retried.
            identities.lastMatchError = error.localizedDescription
            updateTranscription(id) { $0.speakerIdentities = identities }
            return
        }

        let decisions = SpeakerIdentityMatcher.match(channels: channels, candidates: candidates)
        guard let current = transcriptions.first(where: { $0.id == id }), current.result == result else { return }
        var renames: [(from: String, to: String)] = []
        for decision in decisions {
            guard let index = identities.entries.firstIndex(where: { $0.anonymousLabel == decision.label }),
                  !identities.entries[index].isManual else { continue }
            identities.entries[index].status = decision.status
            identities.entries[index].score = decision.score
            identities.entries[index].margin = decision.margin
            identities.entries[index].updatedAt = Date()
            if decision.status == .matched, let personID = decision.personID, let name = decision.nameSnapshot {
                identities.entries[index].personID = personID
                identities.entries[index].nameSnapshot = name
                if identities.entries[index].displayLabel != name {
                    renames.append((identities.entries[index].displayLabel, name))
                    identities.entries[index].displayLabel = name
                }
            } else if identities.entries[index].personID != nil {
                // A previous automatic name no longer holds; restore the anonymous label.
                renames.append((identities.entries[index].displayLabel, identities.entries[index].anonymousLabel))
                identities.entries[index].displayLabel = identities.entries[index].anonymousLabel
                identities.entries[index].personID = nil
                identities.entries[index].nameSnapshot = nil
            }
        }
        identities.matchKey = key
        identities.lastMatchError = nil
        updateTranscription(id) { $0.speakerIdentities = identities }
        for rename in renames where rename.from != rename.to {
            renameSpeaker(rename.from, to: rename.to, inTranscription: id, isManual: false)
        }
    }

    func rematchSessionSpeakers(sessionID: UUID) {
        guard let id = resolveTranscriptionID(forSession: sessionID) else { return }
        matchSessionSpeakers(id, force: true)
    }

    func setCandidatePersons(_ ids: [UUID], sessionID: UUID) {
        guard let id = resolveTranscriptionID(forSession: sessionID) else { return }
        updateTranscription(id) { $0.candidatePersonIDs = ids }
        matchSessionSpeakers(id)
    }

    // MARK: - Manual corrections

    func speakerIdentity(sessionID: UUID, label: String) -> SessionSpeakerIdentity? {
        guard let id = resolveTranscriptionID(forSession: sessionID) else { return nil }
        return transcriptions.first { $0.id == id }?.speakerIdentities?.entry(displayLabel: label)
    }

    /// Links a speaker label to a person (or unlinks with nil). The label takes
    /// the person's name; labels already showing that name merge with it.
    func linkSessionSpeaker(sessionID: UUID, label: String, personID: UUID?) {
        guard let id = resolveTranscriptionID(forSession: sessionID),
              transcriptions.contains(where: { $0.id == id }) else { return }
        let person = SpeakerPersonStore.shared.person(id: personID)
        var identities = transcriptions.first { $0.id == id }?.speakerIdentities ?? SessionSpeakerIdentities()
        let anonymous = identities.entry(displayLabel: label)?.anonymousLabel ?? label
        let target = person?.name ?? anonymous
        let index = identities.entries.firstIndex { $0.displayLabel == label }
            ?? { identities.entries.append(.init(anonymousLabel: label, displayLabel: label, status: .manual)); return identities.entries.count - 1 }()
        identities.entries[index].personID = person?.id
        identities.entries[index].nameSnapshot = person?.name
        identities.entries[index].status = .manual
        identities.entries[index].displayLabel = target
        identities.entries[index].updatedAt = Date()
        updateTranscription(id) { $0.speakerIdentities = identities }
        if target != label {
            renameSpeaker(label, to: target, inTranscription: id, isManual: false)
        }
    }

    /// Records a user rename as a manual identity; a name equal to a library
    /// person links that person.
    func noteManualSpeakerRename(_ current: String, to replacement: String, inTranscription id: UUID) {
        guard var identities = transcriptions.first(where: { $0.id == id })?.speakerIdentities else { return }
        let person = SpeakerPersonStore.shared.person(named: replacement)
        var changed = false
        for index in identities.entries.indices where identities.entries[index].displayLabel == current {
            identities.entries[index].displayLabel = replacement
            identities.entries[index].status = .manual
            identities.entries[index].personID = person?.id
            identities.entries[index].nameSnapshot = person?.name ?? replacement
            identities.entries[index].updatedAt = Date()
            changed = true
        }
        if changed { updateTranscription(id) { $0.speakerIdentities = identities } }
    }

    // MARK: - Save a session speaker to the voice library

    /// Builds a reference voice from this speaker's clean speech, links it to
    /// the chosen person (creating one when none exists by that name), and
    /// prepares the voiceprint in the background.
    @discardableResult
    func saveSessionSpeakerToLibrary(
        sessionID: UUID,
        label: String,
        personName: String,
        existingPersonID: UUID?,
        gender: VoiceReferenceGender
    ) async throws -> SpeakerPerson {
        guard let id = resolveTranscriptionID(forSession: sessionID),
              let job = transcriptions.first(where: { $0.id == id }),
              let result = job.result else { throw SessionSpeakerVoiceError.noSession }
        let activity = SpeakerIdentityActivity.shared
        activity.set(.savingVoice, for: id)
        defer { activity.set(nil, for: id) }

        let anonymous = job.speakerIdentities?.entry(displayLabel: label)?.anonymousLabel ?? label
        let evidence = Self.speakerEvidence(for: job, result: result)
        let ranges = evidence.first { $0.label == anonymous }?.cleanRanges
            ?? evidence.first { $0.label == label }?.cleanRanges
            ?? []
        let clip = try await SessionSpeakerClip.make(
            url: job.sourceURL, ranges: ranges, words: result.words, label: label
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let people = SpeakerPersonStore.shared
        let personName = SpeakerPersonStore.normalizedName(personName)
        let person = people.person(id: existingPersonID) ?? people.person(named: personName)
            ?? people.createPerson(name: personName)
        let reference = try await VoiceLibraryStore.shared.create(VoiceReferenceDraft(
            name: person.name,
            languageCode: ASREngineLanguagePolicy.normalizedISO(result.language) ?? "en",
            gender: gender,
            transcript: clip.transcript,
            sourceAudioURL: clip.url
        ))
        people.link(reference: reference.id, to: person.id)
        linkSessionSpeaker(sessionID: sessionID, label: label, personID: person.id)
        if !job.candidatePersonIDs.contains(person.id) {
            updateTranscription(id) { $0.candidatePersonIDs.append(person.id) }
        }
        return people.person(id: person.id) ?? person
    }

    /// Clean single-speaker seconds available for `label` in a session.
    func cleanSpeechDuration(sessionID: UUID, label: String) -> Double {
        guard let id = resolveTranscriptionID(forSession: sessionID),
              let job = transcriptions.first(where: { $0.id == id }), let result = job.result else { return 0 }
        let anonymous = job.speakerIdentities?.entry(displayLabel: label)?.anonymousLabel ?? label
        let evidence = Self.speakerEvidence(for: job, result: result)
        let ranges = evidence.first { $0.label == anonymous }?.cleanRanges
            ?? evidence.first { $0.label == label }?.cleanRanges ?? []
        return min(SessionSpeakerClip.maximumDuration, ranges.reduce(0) { $0 + max(0, $1.end - $1.start - 0.2) })
    }

    // MARK: - Evidence

    /// Diarization evidence when available; otherwise speaker turns from words
    /// (older or cloud transcripts, without overlap information).
    nonisolated static func speakerEvidence(for job: WorkbenchTranscriptionJob, result: TranscriptionResult) -> [SpeakerChannelEvidence] {
        if let evidence = job.diarizationDiagnostics?.speakerEvidence, !evidence.isEmpty { return evidence }
        var ranges: [String: [SpeechTimeRange]] = [:]
        for turn in SpeakerIdentity.turns(from: result) {
            ranges[turn.speaker, default: []].append(SpeechTimeRange(start: turn.start, end: turn.end))
        }
        return ranges.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { label in
            let clean = (ranges[label] ?? []).filter { $0.end - $0.start >= SpeakerEvidenceBuilder.minimumCleanRange }
            return SpeakerChannelEvidence(
                label: label,
                cleanRanges: clean.sorted { ($0.end - $0.start) > ($1.end - $1.start) },
                activeDuration: (ranges[label] ?? []).reduce(0) { $0 + $1.end - $1.start },
                overlapsWith: []
            )
        }
    }

    private nonisolated static func evidenceDigest(_ evidence: [SpeakerChannelEvidence]) -> String {
        evidence.map { item in
            "\(item.label):\(item.cleanRanges.count):\(String(format: "%.2f", item.cleanDuration))"
        }.joined(separator: ",")
    }
}

/// A reference recording cut from a speaker's clean session speech.
enum SessionSpeakerClip {
    static let maximumDuration = 30.0
    static let gap = 0.15

    struct Clip {
        var url: URL
        var transcript: String
        var duration: Double
    }

    static func make(url: URL, ranges: [SpeechTimeRange], words: [TranscriptionWord], label: String) async throws -> Clip {
        let sampleRate = 24_000.0
        var picked: [SpeechTimeRange] = []
        var total = 0.0
        for range in ranges.sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
            let start = range.start + 0.1
            let end = min(range.end - 0.1, start + (maximumDuration - total))
            guard end - start >= 1 else { continue }
            picked.append(SpeechTimeRange(start: start, end: end))
            total += end - start
            if total >= maximumDuration { break }
        }
        picked.sort { $0.start < $1.start }
        guard total >= SpeakerVoiceprintPolicy.minimumEnrollmentDuration else {
            throw SessionSpeakerVoiceError.notEnoughSpeech(total)
        }
        var samples: [Float] = []
        let silence = [Float](repeating: 0, count: Int(gap * sampleRate))
        for range in picked {
            guard let piece = try? await AudioTrackReader.readMonoFloats(
                from: url, sampleRate: sampleRate, range: range.start...range.end
            ) else { throw SessionSpeakerVoiceError.audioUnavailable }
            if !samples.isEmpty { samples += silence }
            samples += piece
        }
        let transcript = words.filter { word in
            guard let start = word.start, let end = word.end else { return false }
            let middle = (start + end) / 2
            return SpeakerLabelResolver.normalized(word.speaker) == label
                && picked.contains { $0.contains(middle) }
        }.map(\.text)
        let output = FileIO.temporaryFileURL(pathExtension: "wav")
        try writeWAV(samples: samples, sampleRate: sampleRate, to: output)
        return Clip(
            url: output,
            transcript: TranscriptSegmenter.joinedText(transcript),
            duration: Double(samples.count) / sampleRate
        )
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw SessionSpeakerVoiceError.audioUnavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample.isFinite ? sample : 0 }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }
}
