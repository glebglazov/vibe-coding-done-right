import Foundation
import Testing
@testable import vcdr_ios

/// The retired Assistant mode leaves no trace: a saved Assistant becomes AI
/// on, its keys go, and its History entries go. Both steps run at every
/// launch, so a second run must change nothing.
@MainActor
@Suite("Retired Assistant mode", .serialized)
struct RetiredAssistantModeTests {

    // MARK: - Settings migration

    private static let sharedKeys = [
        SharedConstants.defaultAIModeKey,
        SharedConstants.aiModeOverrideKey,
        "shared_selected_text",
        "shared_captured_texts",
    ]
    private static let standardKeys = [
        "ai_processing_assistant_provider",
        "ai_processing_assistant_afm_fallback",
        "transcription_mode_override_assistant",
        "cachedPrompt_assistant",
        AIProcessingSettings.dictationProviderKey,
    ]

    @Test("a saved Assistant default and session become AI on, and the Assistant keys go")
    func savedAssistantBecomesAIOn() {
        withCleanKeys { shared, standard in
            shared.set("assistant", forKey: SharedConstants.defaultAIModeKey)
            shared.set("assistant", forKey: SharedConstants.aiModeOverrideKey)
            shared.set(Data("[\"a\"]".utf8), forKey: "shared_captured_texts")
            shared.set("selected", forKey: "shared_selected_text")
            for key in Self.standardKeys.dropLast() { standard.set("x", forKey: key) }
            standard.set("openai", forKey: AIProcessingSettings.dictationProviderKey)

            LegacySettingsMigrator.migrateIfNeeded()

            #expect(shared.string(forKey: SharedConstants.defaultAIModeKey) == "dictation")
            #expect(shared.string(forKey: SharedConstants.aiModeOverrideKey) == "dictation")
            #expect(SettingOverrides.effectiveAIMode() == .dictation)
            #expect(shared.object(forKey: "shared_captured_texts") == nil)
            #expect(shared.object(forKey: "shared_selected_text") == nil)
            for key in Self.standardKeys.dropLast() { #expect(standard.object(forKey: key) == nil) }
            #expect(standard.string(forKey: AIProcessingSettings.dictationProviderKey) == "openai")
        }
    }

    @Test("AI off and AI on stay as they are, on the first run and the second")
    func otherModesStay() {
        withCleanKeys { shared, _ in
            shared.set("verbatim", forKey: SharedConstants.defaultAIModeKey)
            shared.set("dictation", forKey: SharedConstants.aiModeOverrideKey)

            LegacySettingsMigrator.migrateIfNeeded()
            LegacySettingsMigrator.migrateIfNeeded()

            #expect(shared.string(forKey: SharedConstants.defaultAIModeKey) == "verbatim")
            #expect(shared.string(forKey: SharedConstants.aiModeOverrideKey) == "dictation")
        }
    }

    @Test("a second run after an Assistant migration changes nothing")
    func secondRunChangesNothing() {
        withCleanKeys { shared, _ in
            shared.set("assistant", forKey: SharedConstants.defaultAIModeKey)
            LegacySettingsMigrator.migrateIfNeeded()
            let afterFirst = Self.sharedKeys.map { shared.object(forKey: $0) as? String }

            LegacySettingsMigrator.migrateIfNeeded()

            #expect(Self.sharedKeys.map { shared.object(forKey: $0) as? String } == afterFirst)
            #expect(shared.object(forKey: SharedConstants.aiModeOverrideKey) == nil)
        }
    }

    private func withCleanKeys(_ body: (UserDefaults, UserDefaults) -> Void) {
        let shared = SharedConstants.sharedDefaults
        let standard = UserDefaults.standard
        let savedShared = Self.sharedKeys.map { ($0, shared.object(forKey: $0)) }
        let savedStandard = Self.standardKeys.map { ($0, standard.object(forKey: $0)) }
        Self.sharedKeys.forEach(shared.removeObject(forKey:))
        Self.standardKeys.forEach(standard.removeObject(forKey:))
        defer {
            for (key, value) in savedShared { shared.set(value, forKey: key) }
            for (key, value) in savedStandard { standard.set(value, forKey: key) }
        }
        body(shared, standard)
    }

    // MARK: - History cleanup

    @Test("History loses both Assistant shapes and keeps every other entry, on the first run and the second")
    func historyCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetiredAssistantModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(
            fileURL: root.appendingPathComponent("history.sqlite3")
        ))

        let assistant = record(in: history, label: "Assistant")
        let dictation = record(in: history, label: "Dictation · Casual")
        let macAssistant = record(in: history, label: "Assistant (Remote)")
        let discardedAssistant = discard(in: history, choice: RecordedOutputChoice(
            platform: .ios, modeID: "assistant", styleID: nil, displayLabel: "Assistant"
        ))
        let discardedAIOff = discard(in: history, choice: RecordedOutputChoice(mode: .verbatim, style: .casual))
        let discardedMac = discard(in: history, choice: RecordedOutputChoice(
            platform: .mac, modeID: "assistant", styleID: nil, displayLabel: "Assistant"
        ))

        await RetiredAssistantHistory.remove(from: history)

        let kept = Set(history.conversations.map(\.id))
        #expect(!kept.contains(assistant))
        #expect(!kept.contains(discardedAssistant))
        #expect(kept == [dictation, macAssistant, discardedAIOff, discardedMac])

        await RetiredAssistantHistory.remove(from: history)
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
