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

    /// Most recently modified conversation on disk, if any is loaded.
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

    /// Writes a tombstone event and removes the conversation from memory.
    /// Leaves the snapshot file on disk so unsynced peers can merge correctly.
    func removeConversation(_ conversation: Conversation)

    /// Tombstones every loaded conversation and empties the in-memory list.
    func clearAll()

    /// Reads up to one page of older conversations from disk.
    func loadNextPage()
}
