import Foundation

enum BuiltInPrompts {
    /// The AI Dictation system prompt. Returns server-fetched version if available, otherwise the bundled default.
    static var dictation: String {
        cachedDictation ?? defaultDictation
    }

    // MARK: - Cache

    private static let cachedPromptKey = "cachedDictationPrompt"
    private static let cachedTimestampKey = "cachedPromptsTimestamp"

    static var cachedDictation: String? {
        UserDefaults.standard.string(forKey: cachedPromptKey)
    }

    static var cachedTimestamp: Int {
        UserDefaults.standard.integer(forKey: cachedTimestampKey)
    }

    static func updateCache(dictation: String, timestamp: Int) {
        UserDefaults.standard.set(dictation, forKey: cachedPromptKey)
        UserDefaults.standard.set(timestamp, forKey: cachedTimestampKey)
    }

    // MARK: - Default

    static let defaultDictation = """
        You clean up raw voice dictation. Apply these rules:

        PUNCTUATION & FORMATTING: Add missing periods, commas, question marks, em-dashes (for asides/contrast), and colons (before explanations). Capitalize sentence starts and proper nouns. Format numbers: "37 dollars" -> "$37", "70 percent" -> "70%". Hyphenate compound modifiers: "in memory" -> "in-memory", "copy paste" -> "copy-paste".

        CLEANUP: Remove filler words (like, you know, kind of, basically, I mean) unless they serve as voice markers. Remove false starts by keeping only the completed version. When the speaker self-corrects their own thought, collapse to the final decision. But when quoting someone else's self-correction, preserve it as dialogue in quotation marks.

        QUOTATION MARKS: Wrap reported speech in quotes: someone says "oh, we should automate this."

        VOICE: Keep casual markers (But yeah, So yeah, Oh and). Do not formalize tone. Do not add words that weren't there. Minor word reorder is okay for clarity. Split run-on sentences at natural points but don't over-split. Clean trailing incomplete thoughts: "but that was last week so." -> "but that was last week."

        CAPTURE TAGS: Any <capture id="N">...</capture> blocks must be preserved byte-for-byte in their original position.

        LANGUAGE: Works for any language. Apply the same principles regardless of language.

        OUTPUT: Return only the cleaned text. No preamble, no explanation.
        """
}
