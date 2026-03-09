import Foundation
import CoreGraphics
import OSLog

/// Legacy enum — kept for backward-compatible Mode decoding only.
/// New code uses ProcessingType (for text processing) and OutputDestinationType (for output).
enum PostTranscriptionActionType: String, CaseIterable, Codable {
    case paste = "paste"
    case bash = "bash"
}

struct AudioSettings: Codable, Equatable {
    var preferredInputDeviceID: String?
    var pauseMediaDuringRecording: Bool

    static let `default` = AudioSettings(
        preferredInputDeviceID: nil,
        pauseMediaDuringRecording: true
    )
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let unassigned = HotkeyBinding(keyCode: 0, modifiers: 0)

    /// Default push-to-talk: Cmd+Option+Space
    static let defaultPushToTalk = HotkeyBinding(
        keyCode: 49,
        modifiers: UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
    )

    var isAssigned: Bool {
        keyCode != 0 || modifiers != 0
    }
}

@Observable
final class AppSettings {
    var pushToTalkHotkey: HotkeyBinding {
        didSet { save() }
    }
    var modeSwitcherHotkey: HotkeyBinding {
        didSet { save() }
    }
    var pushToTypeHotkey: HotkeyBinding {
        didSet { save() }
    }
    var toggleRecordingHotkey: HotkeyBinding {
        didSet { save() }
    }
    var copyLatestCaptureHotkey: HotkeyBinding {
        didSet { save() }
    }
    var modes: [Mode] {
        didSet { save() }
    }
    var activeModeID: UUID {
        didSet { save() }
    }
    var outputDestinations: [OutputDestination] {
        didSet { save() }
    }
    var audioSettings: AudioSettings {
        didSet { save() }
    }
    var showModeSwitcherHint: Bool {
        didSet { save() }
    }
    var removeFillerWords: Bool {
        didSet { save() }
    }
    /// Template IDs whose CLI tools are currently available. Not persisted.
    var availableTemplateIDs: Set<String> = []

    /// Modes visible in the mode switcher and default settings list.
    /// Excludes disabled modes and template modes whose tools are unavailable.
    var visibleModes: [Mode] {
        modes.filter { mode in
            guard !mode.isDisabled else { return false }
            if let templateID = mode.templateID {
                return availableTemplateIDs.contains(templateID)
            }
            return true
        }
    }

    /// Active mode looked up by ID, falling back to first visible mode, then first mode overall
    var activeMode: Mode {
        modes.first(where: { $0.id == activeModeID })
            ?? visibleModes.first
            ?? modes.first
            ?? Mode.makeDefault()
    }

    /// Resolves an output destination by ID, falling back to the built-in Paste
    func outputDestination(for id: UUID) -> OutputDestination {
        outputDestinations.first(where: { $0.id == id }) ?? outputDestinations.first ?? OutputDestination.makeDefaultPaste()
    }

    private let userDefaults: UserDefaults

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let pushToTalkHotkey = "pushToTalkHotkey"
        static let modeSwitcherHotkey = "modeSwitcherHotkey"
        static let pushToTypeHotkey = "pushToTypeHotkey"
        static let toggleRecordingHotkey = "toggleRecordingHotkey"
        static let copyLatestCaptureHotkey = "copyLatestCaptureHotkey"
        static let modes = "modes"
        static let activeModeID = "activeModeID"
        static let outputDestinations = "outputDestinations"
        static let audioSettings = "audioSettings"
        static let showModeSwitcherHint = "showModeSwitcherHint"
        static let removeFillerWords = "removeFillerWords"
        // Legacy key for migration
        static let legacyPreferredInputDeviceID = "preferredInputDeviceID"
        // Legacy keys for migration
        static let legacyKeyCode = "hotkeyKeyCode"
        static let legacyModifiers = "hotkeyModifiers"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load push-to-talk hotkey (with migration from legacy keys)
        if let data = userDefaults.data(forKey: Keys.pushToTalkHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.pushToTalkHotkey = decoded
        } else {
            // Migrate from legacy keys
            let savedKeyCode = userDefaults.integer(forKey: Keys.legacyKeyCode)
            let savedModifiers = userDefaults.integer(forKey: Keys.legacyModifiers)
            if savedKeyCode != 0 || savedModifiers != 0 {
                self.pushToTalkHotkey = HotkeyBinding(
                    keyCode: UInt16(savedKeyCode),
                    modifiers: UInt64(savedModifiers)
                )
            } else {
                self.pushToTalkHotkey = .defaultPushToTalk
            }
        }

        // Load mode switcher hotkey (default: unassigned)
        if let data = userDefaults.data(forKey: Keys.modeSwitcherHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.modeSwitcherHotkey = decoded
        } else {
            self.modeSwitcherHotkey = .unassigned
        }

        // Load push-to-type hotkey (default: unassigned)
        if let data = userDefaults.data(forKey: Keys.pushToTypeHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.pushToTypeHotkey = decoded
        } else {
            self.pushToTypeHotkey = .unassigned
        }

        // Load toggle recording hotkey (default: unassigned)
        if let data = userDefaults.data(forKey: Keys.toggleRecordingHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.toggleRecordingHotkey = decoded
        } else {
            self.toggleRecordingHotkey = .unassigned
        }

        // Load copy latest capture hotkey (default: unassigned)
        if let data = userDefaults.data(forKey: Keys.copyLatestCaptureHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.copyLatestCaptureHotkey = decoded
        } else {
            self.copyLatestCaptureHotkey = .unassigned
        }

        // Load modes into local var first (can't use self.modes before all properties init)
        let loadedModes: [Mode]
        if let modesData = userDefaults.data(forKey: Keys.modes),
           let decoded = try? JSONDecoder().decode([Mode].self, from: modesData),
           !decoded.isEmpty {
            loadedModes = decoded
        } else {
            let oldActionType = PostTranscriptionActionType(
                rawValue: userDefaults.string(forKey: "actionType") ?? ""
            ) ?? .paste
            let oldBashCommand = userDefaults.string(forKey: "bashCommand") ?? ""
            let migratedProcessingType: ProcessingType = oldActionType == .bash ? .bashScript : .none
            loadedModes = [Mode(
                id: UUID(),
                name: "Default",
                processingType: migratedProcessingType,
                processingCommand: migratedProcessingType == .bashScript ? oldBashCommand : ""
            )]
        }
        self.modes = loadedModes

        // Load output destinations
        if let data = userDefaults.data(forKey: Keys.outputDestinations),
           let decoded = try? JSONDecoder().decode([OutputDestination].self, from: data),
           !decoded.isEmpty {
            self.outputDestinations = decoded
        } else {
            self.outputDestinations = [OutputDestination.makeDefaultOutputPanel(), OutputDestination.makeDefaultPaste()]
        }

        // Load active mode ID, defaulting to first mode
        if let savedActiveID = userDefaults.string(forKey: Keys.activeModeID),
           let uuid = UUID(uuidString: savedActiveID) {
            self.activeModeID = uuid
        } else {
            self.activeModeID = loadedModes.first?.id ?? UUID()
        }

        // Load mode switcher hint preference (default: true)
        if userDefaults.object(forKey: Keys.showModeSwitcherHint) != nil {
            self.showModeSwitcherHint = userDefaults.bool(forKey: Keys.showModeSwitcherHint)
        } else {
            self.showModeSwitcherHint = true
        }

        // Load filler word removal preference (default: true)
        if userDefaults.object(forKey: Keys.removeFillerWords) != nil {
            self.removeFillerWords = userDefaults.bool(forKey: Keys.removeFillerWords)
        } else {
            self.removeFillerWords = true
        }

        // Load audio settings (with migration from legacy preferredInputDeviceID)
        if let data = userDefaults.data(forKey: Keys.audioSettings),
           let decoded = try? JSONDecoder().decode(AudioSettings.self, from: data) {
            self.audioSettings = decoded
        } else {
            let legacyDeviceID = userDefaults.string(forKey: Keys.legacyPreferredInputDeviceID)
            self.audioSettings = AudioSettings(
                preferredInputDeviceID: legacyDeviceID,
                pauseMediaDuringRecording: true
            )
        }

        // Ensure built-in Output Panel destination exists (migration for existing installs)
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInOutputPanelID }) {
            outputDestinations.append(OutputDestination.makeDefaultOutputPanel())
        }

        // Ensure built-in Copy destination exists (migration for existing installs)
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInCopyID }) {
            outputDestinations.append(OutputDestination.makeDefaultCopy())
        }
    }

    /// Creates template modes for newly available tools and refreshes availability state.
    func refreshTemplateAvailability() {
        availableTemplateIDs = ToolAvailabilityChecker.checkAll()

        // Create missing template modes for available tools
        for template in ModeTemplate.all where availableTemplateIDs.contains(template.id) {
            if !modes.contains(where: { $0.templateID == template.id }) {
                modes.append(template.makeMode())
                Logger.settings.info("Created template mode: \(template.defaultName)")
            }
        }

        // Auto-switch if active mode is no longer visible
        if !visibleModes.contains(where: { $0.id == activeModeID }) {
            if let firstVisible = visibleModes.first {
                activeModeID = firstVisible.id
                Logger.settings.info("Active mode hidden, switched to: \(firstVisible.name)")
            }
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(pushToTalkHotkey) {
            userDefaults.set(encoded, forKey: Keys.pushToTalkHotkey)
        }
        if let encoded = try? JSONEncoder().encode(modeSwitcherHotkey) {
            userDefaults.set(encoded, forKey: Keys.modeSwitcherHotkey)
        }
        if let encoded = try? JSONEncoder().encode(pushToTypeHotkey) {
            userDefaults.set(encoded, forKey: Keys.pushToTypeHotkey)
        }
        if let encoded = try? JSONEncoder().encode(toggleRecordingHotkey) {
            userDefaults.set(encoded, forKey: Keys.toggleRecordingHotkey)
        }
        if let encoded = try? JSONEncoder().encode(copyLatestCaptureHotkey) {
            userDefaults.set(encoded, forKey: Keys.copyLatestCaptureHotkey)
        }
        userDefaults.set(activeModeID.uuidString, forKey: Keys.activeModeID)
        if let encoded = try? JSONEncoder().encode(modes) {
            userDefaults.set(encoded, forKey: Keys.modes)
        }
        if let encoded = try? JSONEncoder().encode(outputDestinations) {
            userDefaults.set(encoded, forKey: Keys.outputDestinations)
        }
        if let encoded = try? JSONEncoder().encode(audioSettings) {
            userDefaults.set(encoded, forKey: Keys.audioSettings)
        }
        userDefaults.set(showModeSwitcherHint, forKey: Keys.showModeSwitcherHint)
        userDefaults.set(removeFillerWords, forKey: Keys.removeFillerWords)
        Logger.settings.info("Settings saved")
    }
}
