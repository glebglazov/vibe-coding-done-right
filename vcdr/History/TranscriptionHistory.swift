import Foundation
import OSLog

@Observable
final class TranscriptionHistory {
    private(set) var conversations: [Conversation] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Constants
    static let maxConversations = 500

    init(directory: URL = TranscriptionHistory.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.conversations = Self.load(from: fileURL, decoder: decoder)
    }

    /// Records a turn in a conversation. Creates a new conversation if one
    /// with the given ID doesn't exist yet; appends to existing otherwise.
    func recordTurn(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        modeID: UUID,
        modeName: String
    ) {
        let turn = ConversationTurn(inputSegments: inputSegments, output: output)

        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].turns.append(turn)
            conversations[index].lastUpdated = .now
            // Move to front (most recent)
            let conversation = conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
        } else {
            let conversation = Conversation(
                id: conversationID,
                turns: [turn],
                modeID: modeID,
                modeName: modeName,
                lastUpdated: .now
            )
            conversations.insert(conversation, at: 0)
        }

        if conversations.count > Self.maxConversations {
            conversations = Array(conversations.prefix(Self.maxConversations))
        }
        save()
    }

    /// Updates the last turn of an existing conversation.
    /// Used for draft accumulation (follow-up dictations) and submission (updating output).
    func updateLastTurn(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        modeID: UUID,
        modeName: String
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              !conversations[index].turns.isEmpty else { return }

        let lastTurnIndex = conversations[index].turns.count - 1
        let existingTurn = conversations[index].turns[lastTurnIndex]
        conversations[index].turns[lastTurnIndex] = ConversationTurn(
            id: existingTurn.id,
            inputSegments: inputSegments,
            output: output
        )
        conversations[index].lastUpdated = .now

        // Move to front (most recent)
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
        save()
    }

    /// Duplicates a conversation under a new ID, preserving all turns.
    /// Used when forking a historical conversation for follow-up.
    func duplicateConversation(originalID: UUID, newID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == originalID }) else { return }
        let original = conversations[index]
        let duplicate = Conversation(
            id: newID,
            turns: original.turns,
            modeID: original.modeID,
            modeName: original.modeName,
            lastUpdated: .now
        )
        conversations.insert(duplicate, at: 0)
        save()
    }

    func removeConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        save()
    }

    func clearAll() {
        conversations.removeAll()
        save()
    }

    /// Latest conversation (newest first)
    var latestConversation: Conversation? {
        conversations.first
    }

    /// Whether the last turn of the given conversation has no output yet (is a draft).
    func hasUnsubmittedDraft(conversationID: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return false
        }
        return conversation.turns.last?.output == nil
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try encoder.encode(conversations)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.app.error("Failed to save transcription history: \(error)")
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [Conversation] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        // Try new format first
        if let conversations = try? decoder.decode([Conversation].self, from: data) {
            return conversations
        }

        // Fall back to legacy format migration
        if let legacyRecords = try? decoder.decode([TranscriptionRecord].self, from: data) {
            return legacyRecords.map { record in
                let captures: [CapturedContext] = record.capturedSelection.map {
                    [CapturedContext(text: $0, source: .selection)]
                } ?? []
                let legacyOutput: String? = (record.processedText != nil && record.processedText != record.text)
                    ? record.processedText : nil
                var segments = [InputSegment(text: record.text)]
                if let capture = captures.first {
                    segments[0] = InputSegment(text: record.text, capture: capture)
                }
                let turn = ConversationTurn(
                    inputSegments: segments,
                    output: legacyOutput
                )
                return Conversation(
                    id: UUID(),
                    turns: [turn],
                    modeID: UUID(), // Unknown — legacy records have no mode reference
                    modeName: "Unknown",
                    lastUpdated: record.timestamp
                )
            }
        }

        return []
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCDR")
    }
}
