import Foundation
import OSLog

/// A saved Mode that the removal of the Assistant deleted. History stores no
/// prompt type, so the History cleanup finds the entries of this Mode by its
/// name and its id, at every launch.
struct RetiredMode: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// The launch step that takes the Assistant out of the saved Modes. It works on
/// the stored values before `AppSettings` reads them, so it runs before the
/// template Modes are made again. A second run changes nothing.
enum AssistantRetirement {
    // MARK: - Constants

    /// The Mode Templates "Assistant (Remote)" and "Assistant (Local)".
    private static let retiredTemplateIDs: Set<String> = ["claude-code", "ollama"]
    private static let retiredPromptType = "assistant"
    private static let retiredModesKey = "retiredModes"
    private static let retiredCachedPromptKey = "cachedPrompt_assistant"

    /// The fields of a stored Mode that decide its fate. `Mode` reads an
    /// unknown value as a default, so the step reads the raw values here.
    private struct StoredMode: Decodable {
        let id: UUID
        let name: String
        let templateID: String?
        let promptType: String?

        var isRetired: Bool {
            templateID.map(retiredTemplateIDs.contains) ?? false
        }
    }

    /// Every Mode this step has deleted, on this launch or an earlier one.
    static func retiredModes(in defaults: UserDefaults) -> [RetiredMode] {
        guard let data = defaults.data(forKey: retiredModesKey),
              let retired = try? JSONDecoder().decode([RetiredMode].self, from: data) else { return [] }
        return retired
    }

    /// Deletes the Assistant Modes from `modesKey`, records them as retired,
    /// and moves an active retired Mode to the "AI on" Mode. A kept Mode whose
    /// prompt type was Assistant is written back with the Dictation prompt.
    static func run(in defaults: UserDefaults, modesKey: String, activeModeIDKey: String) {
        defaults.removeObject(forKey: retiredCachedPromptKey)

        guard let data = defaults.data(forKey: modesKey),
              let stored = try? JSONDecoder().decode([StoredMode].self, from: data),
              let modes = try? JSONDecoder().decode([Mode].self, from: data),
              stored.count == modes.count else { return }

        let retired = stored.filter(\.isRetired).map { RetiredMode(id: $0.id, name: $0.name) }
        let hasAssistantPrompt = stored.contains { !$0.isRetired && $0.promptType == retiredPromptType }
        guard !retired.isEmpty || hasAssistantPrompt else { return }

        let retiredIDs = Set(retired.map(\.id))
        var kept = modes.filter { !retiredIDs.contains($0.id) }

        if let activeID = defaults.string(forKey: activeModeIDKey).flatMap(UUID.init(uuidString:)),
           retiredIDs.contains(activeID) {
            let aiOn = kept.first { $0.templateID == ModeTemplate.aiDictation.id }
                ?? ModeTemplate.aiDictation.makeMode()
            if !kept.contains(where: { $0.id == aiOn.id }) { kept.append(aiOn) }
            defaults.set(aiOn.id.uuidString, forKey: activeModeIDKey)
        }

        guard let keptData = try? JSONEncoder().encode(kept),
              let retiredData = try? JSONEncoder().encode(retiredModes(in: defaults) + retired) else { return }
        defaults.set(keptData, forKey: modesKey)
        defaults.set(retiredData, forKey: retiredModesKey)
        Logger.settings.info("Retired \(retired.count) Assistant Modes")
    }
}
