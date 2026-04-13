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

    /// Default cancel recording: Escape, no modifiers
    static let defaultCancelRecording = HotkeyBinding(keyCode: KeyCodeMap.escapeKeyCode, modifiers: 0)

    /// Default toggle recording: Cmd+Option+Space
    static let defaultToggleRecording = HotkeyBinding(
        keyCode: KeyCodeMap.spaceKeyCode,
        modifiers: UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
    )

    var isAssigned: Bool {
        keyCode != 0 || modifiers != 0
    }

    /// Human-readable shortcut string (e.g., "⌘⌥Space").
    var displayString: String {
        guard isAssigned else { return "" }
        return GlobalHotkeyManager.shortcutDisplayString(
            keyCode: CGKeyCode(keyCode),
            modifiers: CGEventFlags(rawValue: modifiers)
        )
    }
}

@Observable
final class AppSettings {
    // MARK: - Migration Constants

    /// Legacy output panel destination ID, used during migration to redirect modes to paste-to-initial-app
    private static let legacyOutputPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

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
    var variables: [Variable] {
        didSet { save() }
    }

    /// Whether a mode is fully configured and ready to use.
    /// Cloud AI modes require the provider's API key variable to be set.
    func isModeConfigured(_ mode: Mode) -> Bool {
        guard mode.processingType == .cloudAI else { return true }
        let apiKeyName = mode.aiProvider.apiKeyVariableName
        guard let value = variableEnvironment[apiKeyName] else { return false }
        return !value.isEmpty
    }

    /// Modes shown in the settings modes list. Excludes disabled and unavailable templates,
    /// but INCLUDES unconfigured AI modes (so users can see the warning).
    var visibleModes: [Mode] {
        modeConfig.modes.filter { mode in
            guard !mode.isDisabled else { return false }
            if let templateID = mode.templateID {
                return modeConfig.availableTemplateIDs.contains(templateID)
            }
            return true
        }
    }

    /// Modes shown in the mode switcher. Excludes disabled, unavailable template tools,
    /// AND unconfigured AI modes (missing API key).
    var switcherModes: [Mode] {
        visibleModes.filter { isModeConfigured($0) }
    }

    /// Active mode looked up by ID, falling back to first switcher mode, then first mode overall
    var activeMode: Mode {
        modeConfig.modes.first(where: { $0.id == modeConfig.activeModeID })
            ?? switcherModes.first
            ?? modeConfig.modes.first
            ?? Mode.makeDefault()
    }

    /// Resolves an output destination by ID, falling back to the built-in Paste
    func outputDestination(for id: UUID) -> OutputDestination {
        outputDestinations.first(where: { $0.id == id }) ?? outputDestinations.first ?? OutputDestination.makeDefaultPaste()
    }

    private let userDefaults: UserDefaults

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let modeSwitcherHotkey = "modeSwitcherHotkey"
        static let toggleRecordingHotkey = "toggleRecordingHotkey"
        static let copyLatestCaptureHotkey = "copyLatestCaptureHotkey"
        static let cancelRecordingHotkey = "cancelRecordingHotkey"
        static let modes = "modes"
        static let activeModeID = "activeModeID"
        static let outputDestinations = "outputDestinations"
        static let audioSettings = "audioSettings"

        static let variables = "variables"
        static let removeFillerWords = "removeFillerWords"
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
        self.hotkeySettings = hotkeys

        // Load transcription settings
        self.transcriptionSettings = TranscriptionSettings(
            removeFillerWords: Self.boolSetting(from: userDefaults, forKey: Keys.removeFillerWords, default: true)
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
            self.outputDestinations = [OutputDestination.makeDefaultPasteToInitialApp(), OutputDestination.makeDefaultPaste(), OutputDestination.makeDefaultCopy()]
        }

        // Load audio settings (with legacy migration)
        if let data = userDefaults.data(forKey: Keys.audioSettings),
           let decoded = try? JSONDecoder().decode(AudioSettings.self, from: data) {
            self.audioSettings = decoded
        } else {
            let legacyDeviceID = userDefaults.string(forKey: Keys.legacyPreferredInputDeviceID)
            self.audioSettings = AudioSettings(preferredInputDeviceID: legacyDeviceID, pauseMediaDuringRecording: true)
        }

        // Load variables
        self.variables = Self.decodeSetting(from: userDefaults, forKey: Keys.variables, default: [])

        // Ensure API key variables exist (pre-created with empty values for discoverability)
        let requiredVariables = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        let existingNames = Set(variables.map(\.name))
        for name in requiredVariables where !existingNames.contains(name) {
            variables.append(Variable(id: UUID(), name: name, value: ""))
        }

        // Ensure built-in destinations exist (migration for existing installs)
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInCopyID }) {
            outputDestinations.append(OutputDestination.makeDefaultCopy())
        }
        if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInPasteToInitialAppID }) {
            outputDestinations.append(OutputDestination.makeDefaultPasteToInitialApp())
        }

        // Migration: remove outputPanel destination and migrate modes that referenced it
        outputDestinations.removeAll { $0.id == Self.legacyOutputPanelID }
        for i in modeConfig.modes.indices where modeConfig.modes[i].defaultOutputDestinationID == Self.legacyOutputPanelID {
            modeConfig.modes[i].defaultOutputDestinationID = OutputDestination.builtInPasteID
        }

        // Migration: redirect Paste to Initial App modes to plain Paste (Cmd+V)
        for i in modeConfig.modes.indices where modeConfig.modes[i].defaultOutputDestinationID == OutputDestination.builtInPasteToInitialAppID {
            modeConfig.modes[i].defaultOutputDestinationID = OutputDestination.builtInPasteID
        }
    }

    private func save() {
        encode(hotkeySettings.modeSwitcherHotkey, forKey: Keys.modeSwitcherHotkey)
        encode(hotkeySettings.toggleRecordingHotkey, forKey: Keys.toggleRecordingHotkey)
        encode(hotkeySettings.copyLatestCaptureHotkey, forKey: Keys.copyLatestCaptureHotkey)
        encode(hotkeySettings.cancelRecordingHotkey, forKey: Keys.cancelRecordingHotkey)
        userDefaults.set(modeConfig.activeModeID.uuidString, forKey: Keys.activeModeID)
        encode(modeConfig.modes, forKey: Keys.modes)
        encode(outputDestinations, forKey: Keys.outputDestinations)
        encode(audioSettings, forKey: Keys.audioSettings)
        encode(variables, forKey: Keys.variables)
        userDefaults.set(transcriptionSettings.removeFillerWords, forKey: Keys.removeFillerWords)
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

        // Auto-switch if active mode is no longer in the switcher
        if !switcherModes.contains(where: { $0.id == modeConfig.activeModeID }) {
            if let firstAvailable = switcherModes.first {
                modeConfig.activeModeID = firstAvailable.id
                Logger.settings.info("Active mode hidden, switched to: \(firstAvailable.name)")
            }
        }
    }
}
