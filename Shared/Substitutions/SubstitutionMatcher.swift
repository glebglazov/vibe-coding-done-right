import Foundation

/// Applies a list of `Substitution`s to a raw transcript in a single
/// left-to-right pass and returns the rewritten string.
///
/// Matching rules (the agreed contract — see the Shared glossary):
/// - Case-insensitive.
/// - Whole-word-boundary anchored, so a trigger "cat" never fires inside
///   "category".
/// - Longest Trigger Phrase wins when candidate matches overlap; ties are
///   resolved left-to-right. Every phrase of every Substitution competes in the
///   same pass, so a long phrase on one entry beats a short phrase on another.
/// - When two Substitutions claim the same phrase — a Trigger Phrase Clash — the
///   most recently edited one wins, whatever order the list arrives in.
/// - Single pass: a Replacement that is injected is **not** re-scanned for
///   further Trigger Phrases (no recursion, no loops).
/// - Disabled Substitutions (`isEnabled == false`) are skipped.
///
/// This is pure logic over input/output strings — no storage, no pipeline,
/// no UI. The list is captured at construction so consumers build a matcher
/// from their current store snapshot and call ``apply(to:)``.
struct SubstitutionMatcher: Sendable {

    private let substitutions: [Substitution]

    init(substitutions: [Substitution]) {
        self.substitutions = substitutions
    }

    /// Rewrites `transcript`, applying every enabled Substitution exactly once.
    func apply(to transcript: String) -> String {
        guard !transcript.isEmpty else { return transcript }

        // Work on a Character array so indices are stable glyph offsets: we
        // compare case-insensitively without transforming the text, which
        // keeps the selected ranges aligned with the original for rebuilding.
        let characters = Array(transcript)

        let candidates = collectCandidates(in: characters)
        guard !candidates.isEmpty else { return transcript }

        let selected = selectNonOverlapping(candidates)
        return rebuild(characters, applying: selected)
    }

    // MARK: - Candidate match

    /// One whole-word occurrence of an enabled Trigger Phrase in the transcript.
    private struct Candidate {
        /// Inclusive Character index where the match starts.
        let start: Int
        /// Exclusive Character index where the match ends.
        let end: Int
        /// Recency rank of the owning Substitution, newest edit first, used as
        /// the final tie-breaker so a clash resolves to the entry last edited.
        /// Phrases of one Substitution share it: they carry no precedence
        /// between them.
        let order: Int
        /// The Replacement injected verbatim for this match.
        let replacement: String

        var length: Int { end - start }
    }

    // MARK: - Collection

    /// Finds every whole-word, case-insensitive occurrence of every Trigger
    /// Phrase on every enabled Substitution. Each phrase is scanned
    /// independently — its own entry's other phrases included — so all overlaps
    /// are captured for the selection step.
    private func collectCandidates(in characters: [Character]) -> [Candidate] {
        var candidates: [Candidate] = []

        for (order, substitution) in substitutions.rankedByMostRecentlyEdited().enumerated() {
            guard substitution.isEnabled else { continue }

            for phrase in substitution.triggerPhrases {
                let trigger = Array(phrase)
                guard !trigger.isEmpty else { continue }
                guard trigger.count <= characters.count else { continue }

                var index = 0
                while index <= characters.count - trigger.count {
                    let end = index + trigger.count
                    if matches(trigger, in: characters, at: index),
                       isWordBoundaryAnchored(matchStart: index, matchEnd: end, in: characters) {
                        candidates.append(
                            Candidate(start: index, end: end, order: order, replacement: substitution.replacement)
                        )
                        // Skip past this occurrence; a trigger never overlaps itself.
                        index = end
                    } else {
                        index += 1
                    }
                }
            }
        }

        return candidates
    }

    private func matches(_ trigger: [Character], in characters: [Character], at start: Int) -> Bool {
        for offset in 0..<trigger.count where !charactersMatch(characters[start + offset], trigger[offset]) {
            return false
        }
        return true
    }

    private func charactersMatch(_ lhs: Character, _ rhs: Character) -> Bool {
        lhs == rhs || lhs.lowercased() == rhs.lowercased()
    }

    /// True when both edges of the matched range sit on a word boundary — i.e.
    /// the match is not embedded inside a larger word. Mirrors regex `\b`
    /// applied at the start and end of the matched region.
    private func isWordBoundaryAnchored(matchStart: Int, matchEnd: Int, in characters: [Character]) -> Bool {
        let leftAnchored = matchStart == 0
            || !isWordCharacter(characters[matchStart - 1])
            || !isWordCharacter(characters[matchStart])
        let rightAnchored = matchEnd == characters.count
            || !isWordCharacter(characters[matchEnd - 1])
            || !isWordCharacter(characters[matchEnd])
        return leftAnchored && rightAnchored
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Selection

    /// Picks a non-overlapping subset of candidates: longest Trigger Phrase
    /// first, ties broken left-to-right, then by the most recent edit. Selecting
    /// in this rank and rejecting anything that overlaps an already-chosen
    /// match yields the agreed longest-wins / leftmost-on-ties behavior.
    private func selectNonOverlapping(_ candidates: [Candidate]) -> [Candidate] {
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.order < rhs.order
        }

        var selected: [Candidate] = []
        for candidate in ranked {
            let overlapsSelected = selected.contains { existing in
                candidate.start < existing.end && existing.start < candidate.end
            }
            if !overlapsSelected {
                selected.append(candidate)
            }
        }
        return selected
    }

    // MARK: - Rebuild

    /// Emits the original characters in the gaps between selected matches and
    /// each selected match's Replacement in its place. Because output is built
    /// from the original transcript and Replacements are appended verbatim, an
    /// injected Replacement is never re-scanned — the single-pass guarantee.
    private func rebuild(_ characters: [Character], applying selected: [Candidate]) -> String {
        let ordered = selected.sorted { $0.start < $1.start }

        var output = ""
        var cursor = 0
        for candidate in ordered {
            if candidate.start > cursor {
                output.append(contentsOf: characters[cursor..<candidate.start])
            }
            output.append(candidate.replacement)
            cursor = candidate.end
        }
        if cursor < characters.count {
            output.append(contentsOf: characters[cursor..<characters.count])
        }
        return output
    }
}
