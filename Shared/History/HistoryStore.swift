import Foundation
import Observation

/// Persistence boundary for the conversation history. Views observe the
/// concrete conforming type's `@Observable` state via this existential.
///
/// Pagination: the store exposes a windowed view of its on-disk conversations.
/// Callers drive `loadNextPage()` (typically from a list's last-row
/// `onAppear`). Writes (record/remove/clear) surface immediately in
/// `conversations` regardless of pagination state.
@MainActor
protocol HistoryStore: AnyObject, Observable {
    /// Conversations currently loaded in memory, newest first.
    var conversations: [Conversation] { get }

    /// The newest normal conversation in the store, loaded or not, whatever
    /// the filter. Copy Latest and the menu read it, and a Discard must never
    /// reach them.
    var latestConversation: Conversation? { get }

    /// Whether there are more conversations on disk beyond what's loaded.
    var hasMorePages: Bool { get }

    /// Creates or updates the conversation with the given ID.
    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    )

    /// Creates a Discarded Conversation: the verbatim transcript of a run the
    /// user discarded, with no output, and the choice to process it with later.
    func recordDiscarded(
        conversationID: UUID,
        inputSegments: [InputSegment],
        choice: RecordedOutputChoice
    )

    /// Gives a Discarded Conversation its processed output and makes it a
    /// normal entry. It keeps its capture time and its place in the list. Does
    /// nothing when the conversation is gone.
    func resolveDiscarded(conversationID: UUID, output: String, label: String?)

    /// Which conversations `conversations` and paging show. A change starts
    /// paging again from the first page.
    var filter: HistoryFilter { get set }

    /// How many Discarded Conversations the store holds, loaded or not.
    var discardedCount: Int { get }

    /// Writes a tombstone event and removes the conversation, loaded or not.
    /// Does nothing when the store does not hold it. Leaves the snapshot file
    /// on disk so unsynced peers can merge correctly.
    func removeConversation(id: UUID)

    /// Tombstones every loaded conversation and empties the in-memory list.
    func clearAll()

    /// Reads up to one page of older conversations from disk.
    func loadNextPage()
}

nonisolated enum HistoryFilter: Equatable, Sendable {
    case all
    case discarded

    func admits(_ conversation: Conversation) -> Bool {
        switch self {
        case .all: true
        case .discarded: conversation.status.isDiscarded
        }
    }
}
