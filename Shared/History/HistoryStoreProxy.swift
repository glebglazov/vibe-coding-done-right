import Foundation
import OSLog

/// Queues history writes until a real store is assigned, then flushes.
/// Mirrors the real store's observable state so views reading through
/// the proxy get proper @Observation invalidation.
@MainActor
@Observable
final class HistoryStoreProxy: HistoryStore {
    private var realStore: (any HistoryStore)?
    private var pendingRecords: [(UUID, [InputSegment], String?, String?)] = []
    private var pendingRemovals: [Conversation] = []

    var conversations: [Conversation] = []
    var latestConversation: Conversation?
    var hasMorePages: Bool = false

    func setRealStore(_ store: any HistoryStore) {
        realStore = store
        syncFromRealStore()

        for (id, segments, output, label) in pendingRecords {
            store.record(conversationID: id, inputSegments: segments, output: output, label: label)
        }
        pendingRecords.removeAll()

        for conversation in pendingRemovals {
            store.removeConversation(conversation)
        }
        pendingRemovals.removeAll()

        syncFromRealStore()
    }

    func record(conversationID: UUID, inputSegments: [InputSegment], output: String?, label: String?) {
        if let real = realStore {
            real.record(conversationID: conversationID, inputSegments: inputSegments, output: output, label: label)
            syncFromRealStore()
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
            conversations.removeAll { $0.id == conversationID }
            conversations.insert(conversation, at: 0)
            latestConversation = conversation
        }
    }

    func removeConversation(_ conversation: Conversation) {
        if let real = realStore {
            real.removeConversation(conversation)
            syncFromRealStore()
        } else {
            pendingRemovals.append(conversation)
            conversations.removeAll { $0.id == conversation.id }
            latestConversation = conversations.first
        }
    }

    func clearAll() {
        if let real = realStore {
            real.clearAll()
            syncFromRealStore()
        } else {
            pendingRecords.removeAll()
            pendingRemovals.removeAll()
            conversations.removeAll()
            latestConversation = nil
            hasMorePages = false
        }
    }

    func loadNextPage() {
        if let real = realStore {
            real.loadNextPage()
            syncFromRealStore()
        }
    }

    private func syncFromRealStore() {
        conversations = realStore?.conversations ?? []
        latestConversation = realStore?.latestConversation
        hasMorePages = realStore?.hasMorePages ?? false
    }
}
