import AppKit
import Testing
@testable import VoxstudioPro

@Suite("Inline dictation draft safety")
struct VoiceInputDraftInsertionTests {
    @Test func appendingPreservesTypedInstructionsAndMediaReferences() {
        let original = "@demo.mov Keep the best takes"
        let text = VoiceInputDraftInsertion.result(original: original, current: original,
            spoken: "请添加中文字幕", multiline: true, contextIsCurrent: true)
        #expect(text == "@demo.mov Keep the best takes\n请添加中文字幕")
    }

    @Test func emptyAndMultilineDraftsHaveNoExtraBlankLines() {
        #expect(VoiceInputDraftInsertion.result(original: "", current: "", spoken: "Hello", multiline: true, contextIsCurrent: true) == "Hello")
        #expect(VoiceInputDraftInsertion.result(original: "First\n", current: "First\n", spoken: "Second\nThird", multiline: true, contextIsCurrent: true) == "First\nSecond\nThird")
    }

    @Test func lateResultCannotEnterAnotherChatEvenWhenItsDraftIsIdentical() {
        #expect(VoiceInputDraftInsertion.result(original: "Edit this", current: "Edit this", spoken: "Cut the intro", multiline: true, contextIsCurrent: false) == nil)
    }

    @Test func typingDuringRecognitionIsNeverOverwritten() {
        #expect(VoiceInputDraftInsertion.result(original: "Draft", current: "Draft changed", spoken: "Dictation", multiline: true, contextIsCurrent: true) == nil)
    }

    @Test func singleLineCallersRetainExistingBehaviorAndSilenceAddsNothing() {
        #expect(VoiceInputDraftInsertion.result(original: "Search", current: "Search", spoken: "one\ntwo", multiline: false, contextIsCurrent: true) == "Search one two")
        #expect(VoiceInputDraftInsertion.result(original: "Draft", current: "Draft", spoken: " \n", multiline: true, contextIsCurrent: true) == "Draft")
    }
}
