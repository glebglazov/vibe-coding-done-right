import Foundation
import Testing
@testable import vcdr_mac

/// History loses the entries of the retired Modes and keeps every other entry.
/// The cleanup runs at every launch, so a second run must delete nothing.
@MainActor
@Suite("Retired Mode History")
struct RetiredModeHistoryTests {
    private let retiredRemote = RetiredMode(id: UUID(), name: "Assistant (Remote)")
    private let retiredRenamed = RetiredMode(id: UUID(), name: "Rewrite")
    private let retiredSharingAName = RetiredMode(id: UUID(), name: "Translate")

    @Test("Entries of retired Modes go; AI on, a kept Mode's name and iOS entries stay; a second run deletes nothing")
    func cleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetiredModeHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(
            fileURL: root.appendingPathComponent("history.sqlite3")
        ))

        let remote = record(in: history, label: "Assistant (Remote)")
        let local = record(in: history, label: "Assistant (Local)")
        let renamed = record(in: history, label: "Rewrite")
        let discardedRetired = discard(in: history, choice: RecordedOutputChoice(
            platform: .mac, modeID: retiredRenamed.id.uuidString, styleID: nil, displayLabel: "Rewrite"
        ))
        let aiOn = record(in: history, label: "AI on")
        let keptName = record(in: history, label: "Translate")
        let iosAI = record(in: history, label: "AI · Casual")
        let discardedAIOn = discard(in: history, choice: RecordedOutputChoice(
            platform: .mac, modeID: UUID().uuidString, styleID: nil, displayLabel: "AI on · Casual"
        ))
        let discardedIOS = discard(in: history, choice: RecordedOutputChoice(
            platform: .ios, modeID: retiredRenamed.id.uuidString, styleID: nil, displayLabel: "AI · Casual"
        ))
        let retired = [retiredRemote, retiredRenamed, retiredSharingAName]
        let keptModeNames: Set<String> = ["AI off", "AI on", "Translate"]

        await RetiredModeHistory.remove(from: history, retiredModes: retired, keptModeNames: keptModeNames)

        let kept = Set(history.conversations.map(\.id))
        #expect(kept.isDisjoint(with: [remote, local, renamed, discardedRetired]))
        #expect(kept == [aiOn, keptName, iosAI, discardedAIOn, discardedIOS])

        await RetiredModeHistory.remove(from: history, retiredModes: retired, keptModeNames: keptModeNames)
        #expect(Set(history.conversations.map(\.id)) == kept)
    }

    private func record(in history: LocalHistoryStore, label: String) -> UUID {
        let id = UUID()
        history.record(conversationID: id, inputSegments: [InputSegment(text: "words")], output: "Words.", label: label)
        return id
    }

    private func discard(in history: LocalHistoryStore, choice: RecordedOutputChoice) -> UUID {
        let id = UUID()
        history.recordDiscarded(conversationID: id, inputSegments: [InputSegment(text: "words")], choice: choice)
        return id
    }
}
