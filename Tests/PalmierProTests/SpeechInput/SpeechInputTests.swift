import AVFoundation
import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("Speech input")
struct SpeechInputTests {
    @Test func referenceLibraryLivesInSettings() {
        #expect(!WorkbenchRoute.sidebarRoutes.contains(.voiceLibrary))
        #expect(SettingsTab.allCases.contains(.voiceLibrary))
    }

    @Test(arguments: [
        ("zh-CN", WorkbenchDubLanguage.chinese),
        ("en_US", WorkbenchDubLanguage.english),
        ("yue-Hant", WorkbenchDubLanguage.cantonese),
    ])
    func regionalDetectionSelectsSupportedReferenceLanguage(
        code: String,
        expected: WorkbenchDubLanguage
    ) {
        #expect(WorkbenchDubLanguage.detected(from: code) == expected)
    }

    @Test func automaticReferencePersistsDetectedLanguage() {
        #expect(WorkbenchDubLanguage.automatic.resolvedCode(detectedLanguageCode: "zh-CN") == "zh")
        #expect(WorkbenchDubLanguage.automatic.resolvedCode(detectedLanguageCode: "ar-EG") == "ar")
        #expect(WorkbenchDubLanguage.french.resolvedCode(detectedLanguageCode: "zh-CN") == "fr")
    }

    @Test func decodingStopsAtTenSeconds() async throws {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            do {
                let output = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
                buffer.frameLength = 192_000
                let data = try #require(buffer.floatChannelData?[0])
                for index in 0..<192_000 { data[index] = index < 160_000 ? 0.1 : 0.8 }
                try output.write(from: buffer)
            }
            let samples = try await SpeechInputAudio.samples(from: url)
            #expect(samples.count == 160_000)
            #expect(samples.allSatisfy { abs($0 - 0.1) < 0.001 })
        }.value
    }

    @Test func quickInputCanReadAudioPastReferenceLimit() async throws {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
                buffer.frameLength = 192_000
                let channel = try #require(buffer.floatChannelData?[0])
                for index in 0..<192_000 { channel[index] = index < 160_000 ? 0.1 : 0.8 }
                try file.write(from: buffer)
            }

            let samples = try await SpeechInputAudio.samples(
                from: url,
                range: 10...12,
                maximumDuration: nil
            )
            #expect(samples.count == 32_000)
            #expect(samples.allSatisfy { abs($0 - 0.8) < 0.001 })
        }.value
    }

    @Test func quickInputPlansOverlappingBoundedSegments() {
        let segments = SpeechInputSegmentPlanner.segments(forDuration: 181)
        #expect(segments.allSatisfy { $0.upperBound - $0.lowerBound <= 20 })
        #expect(segments[0] == 0...20)
        #expect(segments[1].lowerBound < segments[0].upperBound)
        #expect(segments.last?.upperBound == 181)
    }

    @Test func quickInputMergesOverlappingText() {
        #expect(SpeechInputTextMerger.append("hello world", "world again") == "hello world again")
        #expect(SpeechInputTextMerger.append("第一句话", "第二句话") == "第一句话\n第二句话")
    }

    @MainActor
    @Test func escapeKeepsVoiceInputDraft() {
        let coordinator = VoiceInputCoordinator()
        coordinator.draft = "Keep this"
        coordinator.dismiss()
        #expect(coordinator.draft == "Keep this")
        coordinator.shutdown()
    }

    @MainActor
    @Test func emptyVoiceInputDoesNotCopy() {
        let coordinator = VoiceInputCoordinator()
        let pasteboard = NSPasteboard.withUniqueName()
        #expect(!coordinator.submit(pasteboard: pasteboard))
        coordinator.shutdown()
    }

    @MainActor
    @Test func voiceInputCopiesThenClearsDraft() {
        let coordinator = VoiceInputCoordinator()
        let pasteboard = NSPasteboard.withUniqueName()
        coordinator.draft = "Copy this"
        #expect(coordinator.submit(pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Copy this")
        #expect(coordinator.draft.isEmpty)
        coordinator.shutdown()
    }

    @MainActor
    @Test func voiceInputPresentationCreatesVisiblePanel() {
        let coordinator = VoiceInputCoordinator()
        coordinator.present()
        let panel = NSApp.windows.first { $0.title == "Voice Input" }
        #expect(panel?.isVisible == true)
        coordinator.dismiss()
        coordinator.shutdown()
    }

    @MainActor
    @Test func fieldVoiceInputInsertsWithoutChangingClipboard() {
        var field = ""
        let coordinator = VoiceInputCoordinator(onInsert: { field = $0; return true })
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("Existing clipboard", forType: .string)
        coordinator.draft = "Spoken script"
        #expect(coordinator.submit(pasteboard: pasteboard))
        #expect(field == "Spoken script")
        #expect(pasteboard.string(forType: .string) == "Existing clipboard")
        #expect(coordinator.draft.isEmpty)
        coordinator.shutdown()
    }

    @MainActor
    @Test func changedFieldKeepsDictationForRecovery() {
        let coordinator = VoiceInputCoordinator(onInsert: { _ in false })
        coordinator.draft = "Keep this dictation"
        #expect(!coordinator.submit(pasteboard: .withUniqueName()))
        #expect(coordinator.draft == "Keep this dictation")
        #expect(coordinator.errorMessage != nil)
        coordinator.shutdown()
    }

    @Test func recognizedReferenceSavesMatchingPrefix() async throws {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
                buffer.frameLength = 192_000
                let channel = try #require(buffer.floatChannelData?[0])
                for index in 0..<192_000 { channel[index] = 0.3 * sin(Float(index) * 0.15) }
                try file.write(from: buffer)
            }
            let prepared = try await VoiceReferenceProcessor.shared.prepare(sourceURL: url, usesRecognizedPrefix: true)
            defer { try? FileManager.default.removeItem(at: prepared.URL) }
            #expect(abs(prepared.duration - 10) < 0.01)
        }.value
    }

    @MainActor
    @Test func cancellationRejectsLateRecognition() async {
        let gate = RecognitionGate()
        let controller = SpeechInputController { _, _ in await gate.result() }
        var delivered = false
        controller.start(sourceURL: URL(fileURLWithPath: "/unused.wav")) { _ in delivered = true }
        await gate.waitUntilStarted()
        let cancellation = controller.cancel()
        await gate.finish()
        await cancellation?.value
        #expect(controller.state == .idle)
        #expect(!delivered)
    }
}

private actor RecognitionGate {
    private var pending: CheckedContinuation<SpeechInputResult, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func result() async -> SpeechInputResult {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: SpeechInputResult(text: "late", languageCode: "en", engine: .parakeet))
        pending = nil
    }
}
