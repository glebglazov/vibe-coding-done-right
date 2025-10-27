import Foundation

/// Mode that passes through the raw transcribed text without any processing
class PassThroughMode: Mode {
    let id = UUID()
    let name = "Pass Through"
    let description = "No processing - sends raw transcription"

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        // No processing, just return the original text
        return text
    }
}
