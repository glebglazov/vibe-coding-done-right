import Foundation

/// Available AI processing prompt modes.
/// Raw values match the server's prompt keys for cache lookup.
enum AIPromptMode: String, CaseIterable, Codable {
    case verbatim
    case dictation
    case assistant

    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .dictation: "Dictation"
        case .assistant: "Assistant"
        }
    }

    /// Whether this mode is currently available for selection.
    /// Used to filter the picker — allows defining enum cases before they're ready.
    var isAvailable: Bool {
        switch self {
        case .verbatim: true
        case .dictation: true
        case .assistant: true
        }
    }

    /// Modes that should appear in the UI picker.
    static var availableModes: [AIPromptMode] {
        allCases.filter(\.isAvailable)
    }

    /// Whether style transformations (capitalization, punctuation) should be applied for this mode.
    /// Verbatim and dictation produce user text that benefits from styling; assistant produces AI output that shouldn't be restyled.
    var appliesStyles: Bool {
        switch self {
        case .verbatim: true
        case .dictation: true
        case .assistant: false
        }
    }

    var usesCaptures: Bool {
        switch self {
        case .verbatim, .dictation: false
        case .assistant: true
        }
    }

    /// Cycles verbatim → dictation → assistant → verbatim.
    var next: AIPromptMode {
        switch self {
        case .verbatim: .dictation
        case .dictation: .assistant
        case .assistant: .verbatim
        }
    }
}
