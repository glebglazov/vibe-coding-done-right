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
        input: String,
        output: String,
        capturedSelection: String?,
        modeID: UUID,
        modeName: String,
        hadExternalProcessing: Bool = false
    ) {
        let turn = Conversation.Turn(
            id: UUID(),
            input: input,
            output: output,
            capturedSelection: capturedSelection,
            timestamp: .now
        )

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
                lastUpdated: .now,
                hadExternalProcessing: hadExternalProcessing
            )
            conversations.insert(conversation, at: 0)
        }

        if conversations.count > Self.maxConversations {
            conversations = Array(conversations.prefix(Self.maxConversations))
        }
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
                let turn = Conversation.Turn(
                    id: UUID(),
                    input: record.text,
                    output: record.processedText ?? record.text,
                    capturedSelection: record.capturedSelection,
                    timestamp: record.timestamp
                )
                return Conversation(
                    id: UUID(),
                    turns: [turn],
                    modeID: UUID(), // Unknown — legacy records have no mode reference
                    modeName: "Unknown",
                    lastUpdated: record.timestamp,
                    hadExternalProcessing: record.processedText != nil && record.processedText != record.text
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
