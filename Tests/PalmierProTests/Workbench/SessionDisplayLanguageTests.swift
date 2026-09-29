import Foundation
import Testing
@testable import PalmierPro

@Suite("Independent session display languages")
struct SessionDisplayLanguageTests {
    @Test func changingSubtitlesPreservesTheUnchosenTranscriptAfterReload() throws {
        var job = Self.job()
        let modifiedAt = job.modifiedAt
        let changed = job.rememberDisplayLanguage("JA", for: .subtitles)
        #expect(changed)
        let restored = try Self.reload(job)

        #expect(restored.transcriptDisplayLanguageCode == "zh-Hans")
        #expect(restored.subtitleDisplayLanguageCode == "ja")
        #expect(restored.selectedTranslationLanguageCode == "ja")
        #expect(restored.modifiedAt == modifiedAt)
    }

    @Test func changingTranscriptPreservesTheUnchosenSubtitles() throws {
        var job = Self.job()
        job.rememberDisplayLanguage("ja", for: .transcript)
        let restored = try Self.reload(job)

        #expect(restored.transcriptDisplayLanguageCode == "ja")
        #expect(restored.subtitleDisplayLanguageCode == "zh-Hans")
    }

    @Test func originalIsPreservedWhileTheOtherTabChanges() throws {
        var job = Self.job()
        job.rememberDisplayLanguage(nil, for: .transcript)
        job.rememberDisplayLanguage("ja", for: .subtitles)
        let restored = try Self.reload(job)

        #expect(restored.transcriptDisplayLanguageCode == "")
        #expect(restored.subtitleDisplayLanguageCode == "ja")
        let changed = job.rememberDisplayLanguage("ja", for: .subtitles)
        #expect(!changed)
    }

    @Test func originalDefaultDoesNotBecomeATranslation() throws {
        var job = Self.job()
        job.selectedTranslationLanguageCode = nil
        job.rememberDisplayLanguage("ja", for: .subtitles)
        let restored = try Self.reload(job)

        #expect(restored.transcriptDisplayLanguageCode == "")
        #expect(restored.subtitleDisplayLanguageCode == "ja")
    }

    @Test func legacySnapshotsKeepUnsetPreferencesUntilAChoice() throws {
        let job = Self.job()
        let restored = try Self.reload(job)
        #expect(restored.transcriptDisplayLanguageCode == nil)
        #expect(restored.subtitleDisplayLanguageCode == nil)
        #expect(restored.selectedTranslationLanguageCode == "zh-Hans")
    }

    private static func job() -> WorkbenchTranscriptionJob {
        WorkbenchTranscriptionJob(
            sourcePath: "/tmp/language-test.wav",
            translationTracks: ["zh-Hans", "ja"].map { code in
                WorkbenchTranslationTrack(
                    languageCode: code,
                    track: SubtitleTrack(sourceLanguage: "en", language: code, cues: [])
                )
            },
            selectedTranslationLanguageCode: "zh-Hans"
        )
    }

    private static func reload(_ job: WorkbenchTranscriptionJob) throws -> WorkbenchTranscriptionJob {
        try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: JSONEncoder().encode(job))
    }
}
