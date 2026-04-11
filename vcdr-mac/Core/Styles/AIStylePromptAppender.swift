import Foundation
import OSLog

/// Appends style dynamic prompts to AI mode system prompts (macOS only).
///
/// For Cloud AI and Local Agent modes, this appends the `Style.dynamicPrompt`
/// to the system prompt after mode-specific instructions. This allows style
/// preferences to have the final word in case of conflicts with mode behavior.
///
/// For v1, dynamicPrompt is always nil/empty, so this has no visible effect —
/// but the architecture is ready for future LLM-based style enhancements.
enum AIStylePromptAppender {

    /// Appends the style's dynamic prompt to the system prompt if present.
    ///
    /// - Parameters:
    ///   - systemPrompt: The base system prompt from mode configuration
    ///   - style: The effective style for this capture
    /// - Returns: The system prompt with style prompt appended (if any)
    static func appendStylePrompt(to systemPrompt: String, style: Style) -> String {
        // Only append if there's a non-empty dynamic prompt
        guard let dynamicPrompt = style.dynamicPrompt, !dynamicPrompt.isEmpty else {
            return systemPrompt
        }

        // Append style prompt after mode-specific prompt with clear separation
        // This ensures style preferences override mode behavior if there's a conflict
        let separator = systemPrompt.isEmpty ? "" : "\n\n"
        let result = systemPrompt + separator + dynamicPrompt

        Logger.styles.debug("Appended style prompt for \"\(style.name)\"")
        return result
    }

    /// Checks if the style has a dynamic prompt that should be appended.
    ///
    /// - Parameter style: The style to check
    /// - Returns: true if the style has a non-empty dynamic prompt
    static func hasDynamicPrompt(_ style: Style) -> Bool {
        guard let dynamicPrompt = style.dynamicPrompt else { return false }
        return !dynamicPrompt.isEmpty
    }
}
