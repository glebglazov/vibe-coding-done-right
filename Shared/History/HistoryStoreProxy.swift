import Foundation
import OSLog

/// Queues history writes until a real store is assigned, then flushes.
///
/// Once the real store is assigned, every read goes straight to it, so a
/// conversation a sync pass brings in reaches the history views the moment the
/// store has it, and redraws whatever read it.
@MainActor
@Observable
final class HistoryStoreProxy: HistoryStore {
    private var realStore: (any HistoryStore)?
    private var pendingRecords: [(UUID, [InputSegment], String?, String?)] = []
    private var pendingRemovals: [Conversation] = []

    /// What the writes made before the real store was assigned add up to,
    /// shown until it is.
    private var pendingConversations: [Conversation] = []

    var conversations: [Conversation] {
        realStore?.conversations ?? pendingConversations
    }

    var latestConversation: Conversation? {
        realStore.map { $0.latestConversation } ?? pendingConversations.first
    }

    var hasMorePages: Bool {
        realStore?.hasMorePages ?? false
    }

    func setRealStore(_ store: any HistoryStore) {
        for (id, segments, output, label) in pendingRecords {
            store.record(conversationID: id, inputSegments: segments, output: output, label: label)
        }
        pendingRecords.removeAll()

        for conversation in pendingRemovals {
            store.removeConversation(conversation)
        }
        pendingRemovals.removeAll()
        pendingConversations.removeAll()

        realStore = store
    }

    func record(conversationID: UUID, inputSegments: [InputSegment], output: String?, label: String?) {
        if let real = realStore {
            real.record(conversationID: conversationID, inputSegments: inputSegments, output: output, label: label)
        } else {
            pendingRecords.append((conversationID, inputSegments, output, label))
            let conversation = Conversation(
                id: conversationID,
                inputSegments: inputSegments,
                output: output,
                label: label,
                lastUpdated: Date(),
                schemaVersion: Conversation.currentSchemaVersion,
                extras: [:]
            )
            pendingConversations.removeAll { $0.id == conversationID }
            pendingConversations.insert(conversation, at: 0)
        }
    }

    func removeConversation(_ conversation: Conversation) {
        if let real = realStore {
            real.removeConversation(conversation)
        } else {
            pendingRemovals.append(conversation)
            pendingConversations.removeAll { $0.id == conversation.id }
        }
    }

    func clearAll() {
        if let real = realStore {
            real.clearAll()
        } else {
            pendingRecords.removeAll()
            pendingRemovals.removeAll()
            pendingConversations.removeAll()
        }
    }

    func loadNextPage() {
        realStore?.loadNextPage()
    }
}
