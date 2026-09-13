import Foundation

@main
struct VerifySemanticContract {
    static func main() {
        let valid: [(String, [String])] = [
            ("echo echo end", ["echo", "echo", "end"]),
            ("Use  API\t版本2。继续", ["Use  API\t版本2。", "继续"]),
            ("ซับภาษาไทยไม่มีช่องว่าง", ["ซับภาษาไทย", "ไม่มีช่องว่าง"]),
            ("مرحبا بالعالم. ثم نتابع.", ["مرحبا بالعالم.", "ثم نتابع."]),
            ("Cafe\u{301} 👩🏽‍💻 🇸🇬", ["Cafe\u{301}", "👩🏽‍💻", "🇸🇬"]),
        ]
        for (source, lines) in valid {
            precondition(SubtitleBoundaryValidator.sourceSlices(sourceText: source, proposedLines: lines) == lines)
        }
        let invalid: [(String, [String])] = [
            ("echo echo end", ["echo", "end"]), ("one two", ["one"]),
            ("one two", ["two", "one"]), ("one  two", ["one two"]),
            ("one", ["one", "one"]), ("one", []), ("one", ["", "one"]),
            ("Cafe\u{301}", ["Café"]), ("e\u{301}", ["e", "\u{301}"]),
            ("👩🏽‍💻", ["👩", "🏽‍💻"]), ("🇸🇬", ["🇸", "🇬"]),
        ]
        for (source, lines) in invalid {
            precondition(SubtitleBoundaryValidator.sourceSlices(sourceText: source, proposedLines: lines) == nil)
        }
        let source = "a文กمe\u{301}👨‍👩‍👧‍👦"
        for repeatCount in 1...20 {
            let characters = Array(String(repeating: source, count: repeatCount))
            for cut in 1..<characters.count {
                let lines = [String(characters[..<cut]), String(characters[cut...])]
                precondition(SubtitleBoundaryValidator.sourceSlices(sourceText: String(characters), proposedLines: lines) == lines)
            }
        }
        let lines = ["Keep this.", "A longer source span.", "And this."]
        let repaired = SubtitleBoundaryValidator.applyingRepairs(
            [.init(id: 1, lines: ["A longer", "source span."])], to: lines, indices: [1]
        )
        precondition(repaired == ["Keep this.", "A longer", "source span.", "And this."])
        precondition(SubtitleBoundaryValidator.applyingRepairs(
            [.init(id: 0, lines: ["Keep this."])], to: lines, indices: [1]
        ) == nil)
        precondition(SubtitleBoundaryValidator.applyingRepairs(
            [.init(id: 1, lines: ["Changed."])], to: lines, indices: [1]
        ) == nil)
        print("Swift source-slice and repair contracts passed (1,240 generated partitions plus edge cases).")
    }
}
