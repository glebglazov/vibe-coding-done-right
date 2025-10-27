import Foundation

/// Mode that disables AI processing and sends raw transcribed text
class DisabledMode: Mode {
    let id = UUID()
    let name = "Disabled"
    let description = "No AI processing - raw transcription only"

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        // No processing, just return the original text
        return text
    }
}
