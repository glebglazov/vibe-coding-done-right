import Foundation

struct BashScriptPreset: Identifiable {
    let id: String
    let name: String
    let processingCommand: String
    let systemPromptEnabled: Bool
    let systemPrompt: String
    let parameters: [ModeParameter]

    /// Applies the preset to a mode, overwriting processing-related fields only.
    func apply(to mode: inout Mode) {
        mode.processingType = .bashScript
        mode.processingCommand = processingCommand
        mode.systemPromptEnabled = systemPromptEnabled
        mode.systemPrompt = systemPrompt
        mode.parameters = parameters
    }
}

// MARK: - Built-in Presets

extension BashScriptPreset {
    static let claudeAPI = BashScriptPreset(
        id: "claude-api",
        name: "Claude API",
        processingCommand: """
            curl -s https://api.anthropic.com/v1/messages \
              -H "content-type: application/json" \
              -H "x-api-key: $ANTHROPIC_API_KEY" \
              -H "anthropic-version: 2023-06-01" \
              -d "$(jq -n --arg prompt "$VCDR_TEXT" '{
                model: "claude-haiku-4-5-20251001",
                max_tokens: 1024,
                messages: [{role: "user", content: $prompt}]
              }')" | jq -r '.content[0].text'
            """,
        systemPromptEnabled: true,
        systemPrompt: """
            You clean up raw voice dictation. Apply these rules:

            PUNCTUATION & FORMATTING: Add missing periods, commas, question marks, em-dashes (for asides/contrast), and colons (before explanations). Capitalize sentence starts and proper nouns. Format numbers: "37 dollars" -> "$37", "70 percent" -> "70%". Hyphenate compound modifiers: "in memory" -> "in-memory", "copy paste" -> "copy-paste".

            CLEANUP: Remove filler words (like, you know, kind of, basically, I mean) unless they serve as voice markers. Remove false starts by keeping only the completed version. When the speaker self-corrects their own thought, collapse to the final decision. But when quoting someone else's self-correction, preserve it as dialogue in quotation marks.

            QUOTATION MARKS: Wrap reported speech in quotes: someone says "oh, we should automate this."

            VOICE: Keep casual markers (But yeah, So yeah, Oh and). Do not formalize tone. Do not add words that weren't there. Minor word reorder is okay for clarity. Split run-on sentences at natural points but don't over-split. Clean trailing incomplete thoughts: "but that was last week so." -> "but that was last week."

            CAPTURE TAGS: Any <capture-N>...</capture-N> blocks must be preserved byte-for-byte in their original position.

            LANGUAGE: Works for any language. Apply the same principles regardless of language.

            OUTPUT: Return only the cleaned text. No preamble, no explanation.
            """,
        parameters: []
    )

    static let all: [BashScriptPreset] = [.claudeAPI]
}
