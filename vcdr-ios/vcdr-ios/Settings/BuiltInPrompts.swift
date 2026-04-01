import Foundation

enum BuiltInPrompts {
    // MARK: - Public API

    /// Returns the prompt for the given mode: server-cached if available, otherwise bundled default.
    static func prompt(for mode: AIPromptMode) -> String {
        cachedPrompt(for: mode) ?? defaultPrompt(for: mode)
    }

    /// Legacy accessor — kept for call sites that specifically need the dictation prompt.
    static var dictation: String {
        prompt(for: .dictation)
    }

    // MARK: - Cache

    private static let cachedTimestampKey = "cachedPromptsTimestamp"

    /// Per-mode cache key: "cachedPrompt_dictation", "cachedPrompt_assistant", etc.
    private static func cacheKey(for mode: AIPromptMode) -> String {
        "cachedPrompt_\(mode.rawValue)"
    }

    static func cachedPrompt(for mode: AIPromptMode) -> String? {
        UserDefaults.standard.string(forKey: cacheKey(for: mode))
    }

    static var cachedTimestamp: Int {
        UserDefaults.standard.integer(forKey: cachedTimestampKey)
    }

    /// Updates cached prompts from the server response.
    /// Only overwrites modes present in the dictionary; others remain unchanged.
    static func updateCache(prompts: [String: String], timestamp: Int) {
        for (key, value) in prompts {
            if let mode = AIPromptMode(rawValue: key) {
                UserDefaults.standard.set(value, forKey: cacheKey(for: mode))
            }
        }
        UserDefaults.standard.set(timestamp, forKey: cachedTimestampKey)
    }

    // MARK: - Defaults

    private static func defaultPrompt(for mode: AIPromptMode) -> String {
        switch mode {
        case .dictation: defaultDictation
        case .assistant: defaultAssistant
        }
    }

    static let defaultDictation = """
        You clean up and restructure raw voice dictation. Apply these rules:

        RESTRUCTURING: Dictated thoughts are often scattered, circular, or take a long time to reach the point. Actively reorganize sentences for clarity: merge fragmented ideas and collapse redundant phrasing. If the speaker says the same thing twice in different words, keep the better version. Do not just fix surface errors — reshape the text so it reads as clear, intentional prose while preserving every idea.

        CLEANUP: Aggressively remove filler words (like, you know, kind of, basically, I mean, so yeah, actually) and verbal crutches. Remove "I think" when it's just a verbal tic, but keep it when expressing genuine uncertainty. Remove false starts by keeping only the completed version.

        SELF-CORRECTIONS: When the speaker corrects their OWN thought, collapse to the final decision. But when the speaker is QUOTING someone else's words — including that person's self-corrections — preserve them as dialogue inside quotation marks. The test: are these the speaker's own words (collapse) or someone else's words being reported (preserve)?

        PUNCTUATION: Add missing periods, commas, question marks, em-dashes (for asides/contrast), and colons (before explanations). Capitalize sentence starts and proper nouns. Format numbers: "37 dollars" -> "$37", "70 percent" -> "70%". Hyphenate compound modifiers: "in memory" -> "in-memory".

        LISTS: When the speaker is clearly listing discrete items, tasks, or action items (e.g., "remind me to X, also Y, and Z"), format as a bullet list using dashes (- item). Do NOT bullet-list narrative paragraphs that discuss multiple points — those stay as prose.

        QUOTATION MARKS: Wrap reported speech in quotes: someone says "oh, we should automate this."

        VOICE: Keep the speaker's exact vocabulary. Never replace casual words with formal synonyms. Do not add words that weren't there. Do not formalize tone. Preserve closing/summary lines — if the speaker wraps up a thought with a short concluding statement, keep it.

        CAPTURE TAGS: Any <capture id="N">...</capture> blocks must be preserved byte-for-byte in their original position.

        LANGUAGE: Works for any language. Same principles apply.

        OUTPUT: Return only the cleaned text. No preamble, no explanation.
        """

    static let defaultAssistant = """
        Act immediately on the user's request. Produce only the requested output — no follow-up questions, no preamble, no commentary. The user's input is voice-dictated (inside <dictation> tags) and may contain minor transcription errors — interpret the intent.
        """
}
