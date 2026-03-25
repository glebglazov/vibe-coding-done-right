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

    /// Records or updates a history entry. Creates a new entry if one with the
    /// given ID doesn't exist; replaces the existing one otherwise.
    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        modeID: UUID,
        modeName: String
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].inputSegments = inputSegments
            conversations[index].output = output
            conversations[index].lastUpdated = .now
            // Move to front (most recent)
            let conversation = conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
        } else {
            let conversation = Conversation(
                id: conversationID,
                inputSegments: inputSegments,
                output: output,
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

        // Try current format (handles both new flat and legacy multi-turn via Conversation.init(from:))
        if let conversations = try? decoder.decode([Conversation].self, from: data) {
            return conversations
        }

        // Fall back to legacy TranscriptionRecord format
        if let legacyRecords = try? decoder.decode([TranscriptionRecord].self, from: data) {
            return legacyRecords.map { record in
                let capture: CapturedContext? = record.capturedSelection.map {
                    CapturedContext(text: $0, source: .selection)
                }
                let legacyOutput: String? = (record.processedText != nil && record.processedText != record.text)
                    ? record.processedText : nil
                var segments = [InputSegment(text: record.text)]
                if let capture {
                    segments[0] = InputSegment(text: record.text, capture: capture)
                }
                return Conversation(
                    id: UUID(),
                    inputSegments: segments,
                    output: legacyOutput,
                    modeID: UUID(),
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
