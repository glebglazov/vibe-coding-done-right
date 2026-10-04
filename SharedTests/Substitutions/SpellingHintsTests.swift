import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

@Suite("Spelling Hints")
struct SpellingHintsTests {

    private func entry(_ replacement: String, phrases: [String] = [], editedAt seconds: TimeInterval = 0, enabled: Bool = true) -> Substitution {
        Substitution(
            triggerPhrases: phrases,
            replacement: replacement,
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

    @Test("an entry with no Trigger Phrases changes no transcript and still becomes a hint")
    func phraseLessEntryOnlyHints() {
        let hintOnly = entry("Gleb Glazov")

        #expect(SubstitutionMatcher(substitutions: [hintOnly]).apply(to: "gleb glazov called") == "gleb glazov called")
        #expect(SpellingHints([hintOnly]).spellings == ["Gleb Glazov"])
    }

    @Test("the system prompt keeps its own text and gains the hints after it")
    func appendedToSystemPrompt() {
        let prompt = SpellingHints([entry("Gleb Glazov"), entry("+44 7700 900123", editedAt: 1)])
            .appended(to: "Clean up the dictation.")

        #expect(prompt.hasPrefix("Clean up the dictation.\n\n<spelling_hints>"))
        #expect(prompt.contains("- +44 7700 900123\n- Gleb Glazov\n</spelling_hints>"))
        #expect(prompt.contains("Never add one that the speaker did not say."))
    }

    @Test("no hints leave the system prompt untouched")
    func noHintsNoChange() {
        #expect(SpellingHints.none.appended(to: "Clean up.") == "Clean up.")
        #expect(SpellingHints([entry("x", enabled: false)]).appended(to: "") == "")
    }

    @Test("Whisper's prompt is the typed prompt, then the hints that fit in the budget")
    func whisperPromptBudget() {
        let hints = SpellingHints([entry("Gleb", editedAt: 3), entry("Glazovsky", editedAt: 2), entry("VCDR", editedAt: 1)])

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
