import Foundation

/// Append-only event marking a conversation as deleted. Persisted as its own
/// file so peer devices can merge deletes without clobbering each other's edits.
struct ConversationTombstone: Codable, Equatable, Sendable {
    let conversationID: UUID
    let deletedAt: Date
    var schemaVersion: Int
    var extras: [String: AnyJSON]

    init(
        conversationID: UUID,
        deletedAt: Date,
        schemaVersion: Int = 1,
        extras: [String: AnyJSON] = [:]
    ) {
        self.conversationID = conversationID
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
        self.extras = extras
    }
}
