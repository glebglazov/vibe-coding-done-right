import Foundation

/// Where a Conversation is in its life. A discarded one holds the verbatim
/// on-device transcript of a run the user discarded, and no AI output yet.
nonisolated enum ConversationStatus: Equatable, Sendable {
    case normal
    case discarded(RecordedOutputChoice)

    var isDiscarded: Bool {
        if case .discarded = self { return true }
        return false
    }
}

/// The output choices that were set when the run was discarded. A later
/// "Process with AI" uses them as its default. The ids are opaque strings that
/// the platform which wrote them owns.
nonisolated struct RecordedOutputChoice: Equatable, Codable, Sendable {
    enum Platform: String, Codable, Sendable {
        case ios, mac
    }

    let platform: Platform
    /// iOS: `AIPromptMode.rawValue`. Mac: `Mode.id.uuidString`.
    let modeID: String
    /// iOS: `TextStyle.rawValue`. Mac: `Style.id.uuidString`. Nil when the mode
    /// applies no style.
    let styleID: String?
    /// What the history row shows, for example "Dictation · Casual".
    let displayLabel: String

    private enum CodingKeys: String, CodingKey {
        case platform
        case modeID = "mode"
        case styleID = "style"
        case displayLabel = "label"
    }
}
