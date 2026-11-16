import Foundation

/// Whether AI processes the dictation: Verbatim is AI off, Dictation is AI on.
/// Raw values are stored ids (settings, model pins, the prompt cache, synced
/// History) and match the server's prompt keys, so they never change.
enum AIPromptMode: String, CaseIterable, Codable {
    case verbatim
    case dictation

    var displayName: String {
        switch self {
        case .verbatim: "AI off"
        case .dictation: "AI on"
        }
    }

    /// Dictation rewrites what was said, so it is told each Note (ADR-0026).
    /// Verbatim calls no LLM.
    var hintDetail: SpellingHints.Detail {
        switch self {
        case .dictation: .withNotes
        case .verbatim: .spellingsOnly
        }
    }

    var toggled: AIPromptMode {
        switch self {
        case .verbatim: .dictation
        case .dictation: .verbatim
        }
    }
}
