import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Exercises the shared `SubstitutionMatcher` against the agreed matching
/// contract: case-insensitivity, whole-word anchoring, longest-wins /
/// leftmost-on-ties selection, single-pass injection, and disabled-entry
/// skipping. One source tree compiled into both `vcdr-macTests` and
/// `vcdr-iosTests`.
@Suite("SubstitutionMatcher")
struct SubstitutionMatcherTests {

    // MARK: - Helpers

    private func matcher(_ substitutions: Substitution...) -> SubstitutionMatcher {
        SubstitutionMatcher(substitutions: substitutions)
    }

    private func substitution(
        _ trigger: String,
        _ replacement: String,
        enabled: Bool = true
    ) -> Substitution {
        Substitution(triggerPhrase: trigger, replacement: replacement, isEnabled: enabled)
    }

    // MARK: - Model

    @Test("Substitution carries the five fields")
    func substitutionFields() {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_000)
        let sub = Substitution(
            id: id,
            triggerPhrase: "trigger",
            replacement: "replacement",
            lastUpdated: when,
            isEnabled: false
        )

        #expect(sub.id == id)
        #expect(sub.triggerPhrase == "trigger")
        #expect(sub.replacement == "replacement")
        #expect(sub.lastUpdated == when)
        #expect(sub.isEnabled == false)
    }

    // MARK: - Case-insensitivity

    @Test("case-insensitive: 'My Personal Email' at sentence start matches 'my personal email'")
    func caseInsensitiveMatch() {
        let sut = matcher(substitution("my personal email", "gleb@example.com"))

        let output = sut.apply(to: "My Personal Email is the best way to reach me.")

        #expect(output == "gleb@example.com is the best way to reach me.")
    }

    @Test("case-insensitive: an uppercased trigger still matches lowercased transcript text")
    func caseInsensitiveReversed() {
        let sut = matcher(substitution("OH MY ZSH", "Oh My Zsh"))

        let output = sut.apply(to: "i installed oh my zsh today")

        #expect(output == "i installed Oh My Zsh today")
    }

    // MARK: - Word-boundary anchoring

    @Test("word boundary: trigger does not fire inside a larger word")
    func noMatchInsideWord() {
        let sut = matcher(substitution("cat", "feline"))

        #expect(sut.apply(to: "I sorted them into a category.") == "I sorted them into a category.")
        #expect(sut.apply(to: "The bobcat ran off.") == "The bobcat ran off.")
        #expect(sut.apply(to: "concatenate the strings") == "concatenate the strings")
    }

    @Test("word boundary: trigger fires as a standalone word with surrounding punctuation")
    func matchAsWholeWord() {
        let sut = matcher(substitution("cat", "feline"))

        #expect(sut.apply(to: "I love my cat.") == "I love my feline.")
        #expect(sut.apply(to: "cat!") == "feline!")
        #expect(sut.apply(to: "(cat)") == "(feline)")
        #expect(sut.apply(to: "cat") == "feline")
    }

    // MARK: - Longest-match-wins / leftmost-on-ties

    @Test("longest match wins on overlapping triggers")
    func longestMatchWins() {
        let sut = matcher(
            substitution("new york", "NYC"),
            substitution("new york city", "the Big Apple")
        )

        let output = sut.apply(to: "I visited new york city last spring.")

        #expect(output == "I visited the Big Apple last spring.")
    }

    @Test("longest match wins regardless of declaration order")
    func longestMatchWinsRegardlessOfOrder() {
        // Longer trigger declared *after* the shorter one it overlaps.
        let sut = matcher(
            substitution("new york city", "the Big Apple"),
            substitution("new york", "NYC")
        )

        let output = sut.apply(to: "I visited new york city last spring.")

        #expect(output == "I visited the Big Apple last spring.")
    }

    @Test("ties resolved left-to-right on equal-length overlapping triggers")
    func leftmostWinsOnTies() {
        // "ab cd" (chars 0..<5) and "cd ef" (chars 3..<8) overlap and are the
        // same length, so the leftmost match is taken and consumes "cd".
        let sut = matcher(
            substitution("cd ef", "Y"),
            substitution("ab cd", "X")
        )

        let output = sut.apply(to: "ab cd ef")

        #expect(output == "X ef")
    }

    // MARK: - Single pass

    @Test("single pass: an injected Replacement is not re-scanned for triggers")
    func singlePassNoReinjection() {
        let sut = matcher(
            substitution("foo", "bar baz"),
            substitution("baz", "qux")
        )

        let output = sut.apply(to: "foo is here.")

        // "baz" appears only because it is inside foo's Replacement; it must
        // NOT be rewritten to "qux".
        #expect(output == "bar baz is here.")
    }

    @Test("single pass: triggers in the original transcript are each applied once")
    func eachOriginalOccurrenceAppliedOnce() {
        let sut = matcher(substitution("foo", "bar"))

        let output = sut.apply(to: "foo and foo and foo")

        #expect(output == "bar and bar and bar")
    }

    // MARK: - Disabled entries / filler example

    @Test("filler example: 'oh my zsh' is replaced and disabled entries are skipped")
    func fillerExampleAndDisabledSkipped() {
        let sut = matcher(
            substitution("oh my zsh", "Oh My Zsh framework"),
            substitution("secret", "REDACTED", enabled: false)
        )

        let output = sut.apply(to: "I use oh my zsh and have a secret.")

        // Enabled trigger fires; disabled "secret" is left untouched.
        #expect(output == "I use Oh My Zsh framework and have a secret.")
    }

    @Test("a fully disabled list leaves the transcript unchanged")
    func allDisabledNoOp() {
        let sut = matcher(
            substitution("cat", "feline", enabled: false),
            substitution("dog", "canine", enabled: false)
        )

        let transcript = "the cat and the dog"
        #expect(sut.apply(to: transcript) == transcript)
    }

    // MARK: - Edge cases

    @Test("empty transcript and empty list are no-ops")
    func emptyInputs() {
        #expect(matcher(substitution("cat", "feline")).apply(to: "") == "")
        #expect(SubstitutionMatcher(substitutions: []).apply(to: "the cat sat") == "the cat sat")
    }

    @Test("empty trigger phrases are ignored")
    func emptyTriggerIgnored() {
        let sut = matcher(
            substitution("", "NOISE"),
            substitution("cat", "feline")
        )

        #expect(sut.apply(to: "the cat") == "the feline")
    }
}
