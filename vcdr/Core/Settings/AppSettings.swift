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

    /// Default cancel recording: Escape (key code 53, no modifiers)
    static let defaultCancelRecording = HotkeyBinding(keyCode: 53, modifiers: 0)

    /// Default toggle recording: Cmd+Option+Space
    static let defaultToggleRecording = HotkeyBinding(
        keyCode: 49,
        modifiers: UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
    )

    var isAssigned: Bool {
        keyCode != 0 || modifiers != 0
    }
}

@Observable
final class AppSettings {
    var hotkeySettings: HotkeySettings {
        didSet { save() }
    }
    var transcriptionSettings: TranscriptionSettings {
        didSet { save() }
    }
    var modeConfig: ModeConfiguration {
        didSet { save() }
    }
    var outputDestinations: [OutputDestination] {
        didSet { save() }
    }
    var audioSettings: AudioSettings {
        didSet { save() }
    }

    /// Modes visible in the mode switcher and default settings list.
    /// Excludes disabled modes and template modes whose tools are unavailable.
    var visibleModes: [Mode] {
        modeConfig.modes.filter { mode in
            guard !mode.isDisabled else { return false }
            if let templateID = mode.templateID {
                return modeConfig.availableTemplateIDs.contains(templateID)
            }
            return true
        }
    }

    /// Active mode looked up by ID, falling back to first visible mode, then first mode overall
    var activeMode: Mode {
        modeConfig.modes.first(where: { $0.id == modeConfig.activeModeID })
            ?? visibleModes.first
            ?? modeConfig.modes.first
            ?? Mode.makeDefault()
    }

    /// Resolves an output destination by ID, falling back to the built-in Paste
    func outputDestination(for id: UUID) -> OutputDestination {
        outputDestinations.first(where: { $0.id == id }) ?? outputDestinations.first ?? OutputDestination.makeDefaultPaste()
    }

    static let defaultPushToTypeExpandDelay = 500

    private let userDefaults: UserDefaults

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let modeSwitcherHotkey = "modeSwitcherHotkey"
        static let pushToTypeHotkey = "pushToTypeHotkey"
        static let pushToTypeExpandDelay = "pushToTypeExpandDelay"
        static let toggleRecordingHotkey = "toggleRecordingHotkey"
        static let copyLatestCaptureHotkey = "copyLatestCaptureHotkey"
        static let cancelRecordingHotkey = "cancelRecordingHotkey"
        static let modes = "modes"
        static let activeModeID = "activeModeID"
        static let outputDestinations = "outputDestinations"
        static let audioSettings = "audioSettings"
        static let showModeSwitcherHint = "showModeSwitcherHint"
        static let removeFillerWords = "removeFillerWords"
        static let terminatorTemplateEnabled = "terminatorTemplateEnabled"
        static let terminatorTemplate = "terminatorTemplate"
        static let legacyPreferredInputDeviceID = "preferredInputDeviceID"
        static let legacyPushToTalkHotkey = "pushToTalkHotkey"
        static let legacyKeyCode = "hotkeyKeyCode"
        static let legacyModifiers = "hotkeyModifiers"
    }

    // MARK: - Decode/Encode Helpers

    private static func decodeSetting<T: Codable>(
        from defaults: UserDefaults, forKey key: String, default defaultValue: T
    ) -> T {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return defaultValue
        }
        return decoded
    }

    private static func boolSetting(from defaults: UserDefaults, forKey key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : defaultValue
    }

    private func encode<T: Codable>(_ value: T, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(value) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load hotkey settings from individual keys (supports legacy migration)
        var hotkeys = HotkeySettings.default
        hotkeys.modeSwitcherHotkey = Self.decodeSetting(from: userDefaults, forKey: Keys.modeSwitcherHotkey, default: .unassigned)
        hotkeys.pushToTypeHotkey = Self.decodeSetting(from: userDefaults, forKey: Keys.pushToTypeHotkey, default: .unassigned)
        if userDefaults.object(forKey: Keys.pushToTypeExpandDelay) != nil {
            hotkeys.pushToTypeExpandDelay = userDefaults.integer(forKey: Keys.pushToTypeExpandDelay)
        }
        // Toggle recording hotkey with 3-level migration
        if let data = userDefaults.data(forKey: Keys.toggleRecordingHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            hotkeys.toggleRecordingHotkey = decoded
        } else if let data = userDefaults.data(forKey: Keys.legacyPushToTalkHotkey),
                  let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
                  decoded.isAssigned {
            hotkeys.toggleRecordingHotkey = decoded
        } else {
            let savedKeyCode = userDefaults.integer(forKey: Keys.legacyKeyCode)
            let savedModifiers = userDefaults.integer(forKey: Keys.legacyModifiers)
            if savedKeyCode != 0 || savedModifiers != 0 {
                hotkeys.toggleRecordingHotkey = HotkeyBinding(
                    keyCode: UInt16(savedKeyCode), modifiers: UInt64(savedModifiers)
                )
            }
        }
        hotkeys.copyLatestCaptureHotkey = Self.decodeSetting(
            from: userDefaults, forKey: Keys.copyLatestCaptureHotkey, default: .unassigned
        )
        hotkeys.cancelRecordingHotkey = Self.decodeSetting(
            from: userDefaults, forKey: Keys.cancelRecordingHotkey, default: .defaultCancelRecording
        )
        hotkeys.showModeSwitcherHint = Self.boolSetting(from: userDefaults, forKey: Keys.showModeSwitcherHint, default: true)
        self.hotkeySettings = hotkeys

        // Load transcription settings
        self.transcriptionSettings = TranscriptionSettings(
            removeFillerWords: Self.boolSetting(from: userDefaults, forKey: Keys.removeFillerWords, default: true),
            terminatorTemplateEnabled: Self.boolSetting(
                from: userDefaults, forKey: Keys.terminatorTemplateEnabled, default: true
            ),
            terminatorTemplate: userDefaults.string(forKey: Keys.terminatorTemplate) ?? Mode.defaultTerminatorTemplate
        )

        // Load modes (with legacy migration)
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
                id: UUID(), name: "Default",
                processingType: migratedProcessingType,
                processingCommand: migratedProcessingType == .bashScript ? oldBashCommand : ""
            )]
        }
        // Load active mode ID
        let loadedActiveModeID: UUID
        if let savedActiveID = userDefaults.string(forKey: Keys.activeModeID),
           let uuid = UUID(uuidString: savedActiveID) {
            loadedActiveModeID = uuid
        } else {
            loadedActiveModeID = loadedModes.first?.id ?? UUID()
        }
        self.modeConfig = ModeConfiguration(modes: loadedModes, activeModeID: loadedActiveModeID)

        // Load output destinations
        if let data = userDefaults.data(forKey: Keys.outputDestinations),
           let decoded = try? JSONDecoder().decode([OutputDestination].self, from: data),
           !decoded.isEmpty {
            self.outputDestinations = decoded
        } else {
            self.outputDestinations = [OutputDestination.makeDefaultOutputPanel(), OutputDestination.makeDefaultPaste()]
        }

        // Load audio settings (with legacy migration)
        if let data = userDefaults.data(forKey: Keys.audioSettings),
           let decoded = try? JSONDecoder().decode(AudioSettings.self, from: data) {
            self.audioSettings = decoded
        } else {
            let legacyDeviceID = userDefaults.string(forKey: Keys.legacyPreferredInputDeviceID)
            self.audioSettings = AudioSettings(preferredInputDeviceID: legacyDeviceID, pauseMediaDuringRecording: true)
        }

        // Ensure built-in destinations exist (migration for existing installs)
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInOutputPanelID }) {
            outputDestinations.append(OutputDestination.makeDefaultOutputPanel())
        }
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInCopyID }) {
            outputDestinations.append(OutputDestination.makeDefaultCopy())
        }
    }

    private func save() {
        encode(hotkeySettings.modeSwitcherHotkey, forKey: Keys.modeSwitcherHotkey)
        encode(hotkeySettings.pushToTypeHotkey, forKey: Keys.pushToTypeHotkey)
        userDefaults.set(hotkeySettings.pushToTypeExpandDelay, forKey: Keys.pushToTypeExpandDelay)
        encode(hotkeySettings.toggleRecordingHotkey, forKey: Keys.toggleRecordingHotkey)
        encode(hotkeySettings.copyLatestCaptureHotkey, forKey: Keys.copyLatestCaptureHotkey)
        encode(hotkeySettings.cancelRecordingHotkey, forKey: Keys.cancelRecordingHotkey)
        userDefaults.set(hotkeySettings.showModeSwitcherHint, forKey: Keys.showModeSwitcherHint)
        userDefaults.set(modeConfig.activeModeID.uuidString, forKey: Keys.activeModeID)
        encode(modeConfig.modes, forKey: Keys.modes)
        encode(outputDestinations, forKey: Keys.outputDestinations)
        encode(audioSettings, forKey: Keys.audioSettings)
        userDefaults.set(transcriptionSettings.removeFillerWords, forKey: Keys.removeFillerWords)
        userDefaults.set(transcriptionSettings.terminatorTemplateEnabled, forKey: Keys.terminatorTemplateEnabled)
        userDefaults.set(transcriptionSettings.terminatorTemplate, forKey: Keys.terminatorTemplate)
        Logger.settings.info("Settings saved")
    }

    /// Creates template modes for newly available tools and refreshes availability state.
    func refreshTemplateAvailability() async {
        modeConfig.availableTemplateIDs = await ToolAvailabilityChecker.checkAll()

        // Migrate legacy "dictation" template to "plain"
        for i in modeConfig.modes.indices where modeConfig.modes[i].templateID == "dictation" {
            modeConfig.modes[i].templateID = "plain"
            if modeConfig.modes[i].name == "Dictation" {
                modeConfig.modes[i].name = "Plain"
            }
            Logger.settings.info("Migrated dictation template mode to plain")
        }

        // Create missing template modes for available tools
        for template in ModeTemplate.all where modeConfig.availableTemplateIDs.contains(template.id) {
            if !modeConfig.modes.contains(where: { $0.templateID == template.id }) {
                modeConfig.modes.append(template.makeMode())
                Logger.settings.info("Created template mode: \(template.defaultName)")
            }
        }

        // Auto-switch if active mode is no longer visible
        if !visibleModes.contains(where: { $0.id == modeConfig.activeModeID }) {
            if let firstVisible = visibleModes.first {
                modeConfig.activeModeID = firstVisible.id
                Logger.settings.info("Active mode hidden, switched to: \(firstVisible.name)")
            }
        }
    }
}
