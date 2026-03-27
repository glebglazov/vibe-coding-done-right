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
        systemPrompt: "Act immediately on the user's request. Produce only the requested output — no follow-up questions, no preamble, no commentary. Input is voice-dictated: fix grammar, punctuation, and capitalization errors while preserving the original meaning and tone. If no explicit task is given, treat the input as text to clean up and return corrected.",
        parameters: []
    )

    static let all: [BashScriptPreset] = [.claudeAPI]
}
