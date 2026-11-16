import Foundation
import OSLog

/// Deletes the History entries that the retired Assistant mode made on iOS.
/// It runs at every launch, so an entry that sync brings in later from an
/// older build goes at the next launch. The deletes write tombstones, so the
/// entries also go from every other device.
enum RetiredAssistantHistory {
    /// The label an iOS Assistant run got: the mode name alone, because
    /// Assistant applied no Text Style. The Mac's Assistant Modes have other
    /// names, so their entries do not match.
    private static let assistantLabel = "Assistant"

    static func isAssistantEntry(_ conversation: Conversation) -> Bool {
        switch conversation.status {
        case .normal:
            conversation.label == assistantLabel
        case .discarded(let choice):
            choice.platform == .ios && choice.modeID == LegacySettingsMigrator.retiredAssistantModeID
        }
    }

    @MainActor
    static func remove(from history: LocalHistoryStore) async {
        let ids = await history.conversationIDs(matching: isAssistantEntry)
        guard !ids.isEmpty else { return }
        ids.forEach(history.removeConversation(id:))
        Logger.history.info("Removed \(ids.count) Assistant entries from History")
    }
}
