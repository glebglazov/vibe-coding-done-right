import Foundation

/// Shared base system prompt that explains the input structure to AI models
let baseInputStructurePrompt = """
INPUT STRUCTURE:
The user's input is structured with labeled sections to help you understand what is context versus what is the actual user query.

The input may contain these labeled sections:

1. "=== CONTEXT FROM ACTIVE APP ===" - Text content from the application the user was using when they started the capture. This provides environmental context about what the user was looking at.

2. "=== SELECTED TEXT (CONTEXT) ===" - Text the user had selected in their active application. This is reference material for their query.

3. "=== CLIPBOARD CONTENT ===" - Content the user explicitly added from their clipboard.

4. "=== USER QUERY (VOICE) ===" - The user's actual request or question, spoken via voice recording. THIS IS THE PRIMARY USER INSTRUCTION.

5. "=== USER QUERY (TYPED) ===" - The user's actual request or question, typed via keyboard. THIS IS THE PRIMARY USER INSTRUCTION.

Additionally, this system prompt may contain:

6. "=== USER SYSTEM PROMPT ===" - Custom instructions from the user defining your role or how you should behave. Follow these instructions when processing the user's input.

HOW TO INTERPRET:
- The USER QUERY sections (#4 and #5) are your primary instructions. These tell you what the user wants you to do.
- The CONTEXT sections (#1, #2, #3) are reference material. Use these ONLY to inform your response to the user's query.
- If a USER SYSTEM PROMPT section (#6) is present, follow those custom instructions for how to respond.
- If there's no explicit user query section, treat all content as the query itself.
- Respond directly to what the user asks in their query, using the context sections as supporting information.
"""

/// Protocol defining a mode that processes dictated text
protocol Mode: Identifiable {
    /// Unique identifier for the mode
    var id: UUID { get }

    /// Display name of the mode
    var name: String { get }

    /// Description of what this mode does
    var description: String { get }

    /// Process the transcribed text
    /// - Parameter text: The raw transcribed text from WhisperKit
    /// - Returns: The processed text (or original text if no processing needed)
    func process(text: String, using provider: any LLMProvider) async throws -> String
}
