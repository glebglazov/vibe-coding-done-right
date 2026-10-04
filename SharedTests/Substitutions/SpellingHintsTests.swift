import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

@Suite("Spelling Hints")
struct SpellingHintsTests {

    private func entry(_ replacement: String, phrases: [String] = [], note: String = "", editedAt seconds: TimeInterval = 0, enabled: Bool = true) -> Substitution {
        Substitution(
            triggerPhrases: phrases,
            replacement: replacement,
            note: note,
            lastUpdated: Date(timeIntervalSince1970: seconds),
            isEnabled: enabled
        )
    }

    @Test("every enabled entry's Replacement is a hint, with or without Trigger Phrases, most recently edited first")
    func hintsFromEveryEnabledEntry() {
        let hints = SpellingHints([
            entry("Gleb Glazov", editedAt: 1),
            entry("gleb@example.com", phrases: ["my email"], editedAt: 3),
            entry("Powierża", phrases: ["power zha"], editedAt: 2),
            entry("Disabled", editedAt: 4, enabled: false),
            entry("   ", editedAt: 5),
            entry("Gleb Glazov", phrases: ["gleb glasov"], editedAt: 0),
        ])

        #expect(hints.spellings == ["gleb@example.com", "Powierża", "Gleb Glazov"])
    }

    @Test("two spellings that differ only in case keep the more recent one")
    func caseInsensitiveDuplicates() {
        let hints = SpellingHints([entry("vcdr", editedAt: 1), entry("VCDR", editedAt: 2)])

        #expect(hints.spellings == ["VCDR"])
    }

    @Test("an entry with no Trigger Phrases changes no transcript and still becomes a hint")
    func phraseLessEntryOnlyHints() {
        let hintOnly = entry("Gleb Glazov")

        #expect(SubstitutionMatcher(substitutions: [hintOnly]).apply(to: "gleb glazov called") == "gleb glazov called")
        #expect(SpellingHints([hintOnly]).spellings == ["Gleb Glazov"])
    }

    @Test("two spellings that differ only in case keep the Note of the more recent one")
    func caseInsensitiveDuplicatesKeepTheirOwnNote() {
        let hints = SpellingHints([
            entry("vcdr", note: "an old name", editedAt: 1),
            entry("VCDR", note: "my dictation app", editedAt: 2),
        ])

        #expect(hints.hints == [SpellingHints.Hint(spelling: "VCDR", note: "my dictation app")])
    }

    private let notedEntries = [
        Substitution(triggerPhrases: [], replacement: "Gleb Glazov", lastUpdated: Date(timeIntervalSince1970: 0)),
        Substitution(triggerPhrases: ["anja"], replacement: "Anya", note: " my\nsister ", lastUpdated: Date(timeIntervalSince1970: 1)),
    ]

    @Test("spellings only is the block the prompts carried before Notes, byte for byte")
    func spellingsOnlyBlock() {
        let prompt = SpellingHints(notedEntries).appended(to: "Clean up the dictation.", detail: .spellingsOnly)

        #expect(prompt == """
        Clean up the dictation.

        <spelling_hints>
        The speaker often says these names, words and values. When the dictation contains something that sounds like one of them, write it with exactly this spelling. Never add one that the speaker did not say.
        - Anya
        - Gleb Glazov
        </spelling_hints>
        """)
    }

    @Test("with Notes, each spelling that has one carries it in parentheses")
    func withNotesBlock() {
        let prompt = SpellingHints(notedEntries).appended(to: "Clean up the dictation.", detail: .withNotes)

        #expect(prompt == """
        Clean up the dictation.

        <spelling_hints>
        The speaker often says these names, words and values. When the dictation contains something that sounds like one of them, write it with exactly this spelling. Never add one that the speaker did not say.
        - Anya (my sister)
        - Gleb Glazov
        </spelling_hints>
        """)
    }

    @Test("no hints leave the system prompt untouched")
    func noHintsNoChange() {
        #expect(SpellingHints.none.appended(to: "Clean up.", detail: .withNotes) == "Clean up.")
        #expect(SpellingHints([entry("x", enabled: false)]).appended(to: "", detail: .withNotes) == "")
    }

    @Test("Whisper's prompt is the typed prompt, then the hints that fit in the budget")
    func whisperPromptBudget() {
        let hints = SpellingHints([
            entry("Gleb", note: "my own name", editedAt: 3),
            entry("Glazovsky", editedAt: 2),
            entry("VCDR", editedAt: 1),
        ])

        let prompt = WhisperPrompt(typed: " Parakeet ", hints: hints, characterBudget: 20)

        #expect(prompt.text == "Parakeet, Gleb, VCDR")
        #expect(prompt.hintsLeftOut == 1)
    }

    @Test("with nothing typed, Whisper's prompt is the hints alone")
    func whisperPromptHintsOnly() {
        let prompt = WhisperPrompt(typed: "", hints: SpellingHints([entry("Gleb")]))

        #expect(prompt.text == "Gleb")
        #expect(prompt.hintsLeftOut == 0)
        #expect(WhisperPrompt(typed: "", hints: .none).text.isEmpty)
    }
}
