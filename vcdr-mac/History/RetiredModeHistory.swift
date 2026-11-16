import Foundation
import OSLog

/// Deletes the History entries of the Modes that the removal of the Assistant
/// deleted. It runs at every launch, so an entry that sync brings in later from
/// an older build goes at the next launch. The deletes write tombstones, so the
/// entries also go from every other device.
enum RetiredModeHistory {
    // MARK: - Constants

    /// The default names of the two retired Mode Templates. Their Modes can be
    /// gone from this Mac and still have entries from another Mac.
    private static let assistantTemplateNames: Set<String> = ["Assistant (Remote)", "Assistant (Local)"]

    /// A Mac Conversation stores only its label, which is the Mode name. A name
    /// that a kept Mode also has can label that Mode's own runs, so it is never
    /// matched. A Discarded Conversation records the Mode id, so it matches by id.
    private static func matcher(
        retiredModes: [RetiredMode],
        keptModeNames: Set<String>
    ) -> @Sendable (Conversation) -> Bool {
        let retiredLabels = assistantTemplateNames
            .union(retiredModes.map(\.name))
            .subtracting(keptModeNames)
        let retiredIDs = Set(retiredModes.map(\.id.uuidString))
        return { conversation in
            switch conversation.status {
            case .normal:
                conversation.label.map(retiredLabels.contains) ?? false
            case .discarded(let choice):
                choice.platform == .mac && retiredIDs.contains(choice.modeID)
            }
        }
    }

    @MainActor
    static func remove(
        from history: LocalHistoryStore,
        retiredModes: [RetiredMode],
        keptModeNames: Set<String>
    ) async {
        let matches = matcher(retiredModes: retiredModes, keptModeNames: keptModeNames)
        let ids = await history.conversationIDs(matching: matches)
        guard !ids.isEmpty else { return }
        ids.forEach(history.removeConversation(id:))
        Logger.app.info("Removed \(ids.count) entries of retired Modes from History")
    }
}
