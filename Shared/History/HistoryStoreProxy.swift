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
    /// The writes made before the real store was assigned, in the order they
    /// were made, so a resolve or a delete lands after the write it follows.
    private var pendingWrites: [(any HistoryStore) -> Void] = []
    private var pendingFilter: HistoryFilter = .all

    /// What the writes made before the real store was assigned add up to,
    /// shown until it is.
    private var pendingConversations: [Conversation] = []

    var conversations: [Conversation] {
        realStore?.conversations ?? pendingConversations.filter(pendingFilter.admits)
    }

    var latestConversation: Conversation? {
        realStore.map { $0.latestConversation } ?? pendingConversations.first { !$0.status.isDiscarded }
    }

    var hasMorePages: Bool {
        realStore?.hasMorePages ?? false
    }

    var filter: HistoryFilter {
        get { realStore?.filter ?? pendingFilter }
        set {
            if let realStore {
                realStore.filter = newValue
            } else {
                pendingFilter = newValue
            }
        }
    }

    var discardedCount: Int {
        realStore?.discardedCount ?? pendingConversations.filter(\.status.isDiscarded).count
    }

    func setRealStore(_ store: any HistoryStore) {
        store.filter = pendingFilter
        for write in pendingWrites {
            write(store)
        }
        pendingWrites.removeAll()
        pendingConversations.removeAll()

        realStore = store
    }

    func record(conversationID: UUID, inputSegments: [InputSegment], output: String?, label: String?) {
        perform { $0.record(conversationID: conversationID, inputSegments: inputSegments, output: output, label: label) }
        guard realStore == nil else { return }
        showPending(Conversation(
            id: conversationID,
            inputSegments: inputSegments,
            output: output,
            label: label,
            lastUpdated: Date()
        ))
    }

    func recordDiscarded(conversationID: UUID, inputSegments: [InputSegment], choice: RecordedOutputChoice) {
        perform { $0.recordDiscarded(conversationID: conversationID, inputSegments: inputSegments, choice: choice) }
        guard realStore == nil else { return }
        showPending(Conversation(
            id: conversationID,
            inputSegments: inputSegments,
            output: nil,
            label: nil,
            lastUpdated: Date(),
            status: .discarded(choice)
        ))
    }

    func resolveDiscarded(conversationID: UUID, output: String, label: String?) {
        perform { $0.resolveDiscarded(conversationID: conversationID, output: output, label: label) }
        guard realStore == nil,
              let index = pendingConversations.firstIndex(where: { $0.id == conversationID })
        else { return }
        pendingConversations[index].output = output
        pendingConversations[index].label = label
        pendingConversations[index].status = .normal
        pendingConversations[index].lastUpdated = Date()
    }

    func removeConversation(id: UUID) {
        perform { $0.removeConversation(id: id) }
        pendingConversations.removeAll { $0.id == id }
    }

    func clearAll() {
        if let real = realStore {
            real.clearAll()
        } else {
            pendingWrites.removeAll()
            pendingConversations.removeAll()
        }
    }

    func loadNextPage() {
        realStore?.loadNextPage()
    }

    private func perform(_ write: @escaping (any HistoryStore) -> Void) {
        if let realStore {
            write(realStore)
        } else {
            pendingWrites.append(write)
        }
    }

    /// Keeps the pending list newest first, one entry per conversation.
    private func showPending(_ conversation: Conversation) {
        pendingConversations.removeAll { $0.id == conversation.id }
        pendingConversations.insert(conversation, at: 0)
    }
}
