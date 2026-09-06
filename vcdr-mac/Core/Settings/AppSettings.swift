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

    /// Default cancel recording: Shift+Escape
    static let defaultCancelRecording = HotkeyBinding(
        keyCode: KeyCodeMap.escapeKeyCode,
        modifiers: UInt64(CGEventFlags.maskShift.rawValue)
    )

    /// Default toggle recording: Option+/
    static let defaultToggleRecording = HotkeyBinding(
        keyCode: KeyCodeMap.slashKeyCode,
        modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
    )

    /// Default mode switcher: Shift+Option+/
    static let defaultModeSwitcher = HotkeyBinding(
        keyCode: KeyCodeMap.slashKeyCode,
        modifiers: UInt64(CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue)
    )

    var isAssigned: Bool {
        keyCode != 0 || modifiers != 0
    }

    /// The modifier glyphs in the order macOS writes them in a menu.
    private static let modifierGlyphs: [(flag: CGEventFlags, glyph: String)] = [
        (.maskControl, "\u{2303}"),
        (.maskAlternate, "\u{2325}"),
        (.maskShift, "\u{21E7}"),
        (.maskCommand, "\u{2318}")
    ]

    /// Human-readable shortcut string (e.g., "⌘⌥Space").
    var displayString: String {
        guard isAssigned else { return "" }
        let flags = CGEventFlags(rawValue: modifiers)
        var parts = Self.modifierGlyphs.compactMap { flags.contains($0.flag) ? $0.glyph : nil }
        parts.append(KeyCodeMap.name(for: CGKeyCode(keyCode)))
        return parts.joined()
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
    /// The user's Variables — name/value pairs injected into every bash script, and so
    /// the natural home for any other secret a script needs. The Secret Store owns the
    /// list as one item; this mirrors what it held at launch so reads stay synchronous
    /// and observable, and every write goes through to the Store. See
    /// `docs/adr/0009-secrets-live-in-a-synced-keychain-not-userdefaults.md`.
    var variables: [Variable] {
        get { mirroredVariables }
        set {
            mirroredVariables = newValue
            writeVariablesToStore()
            save()
        }
    }

    private var mirroredVariables: [Variable]

    /// Whether the Secret Store refused to answer for the Variables list at launch. The
    /// mirrored list is empty then, which is why it may never be mistaken for an empty list.
    private var variablesUnreadable: Bool

    /// API keys per cloud AI Provider — the single source of truth for AI calls.
    /// The Secret Store owns them; this mirrors what it held at launch so reads stay
    /// synchronous and observable, and every write goes through to the Store. See
    /// `docs/adr/0001-ai-provider-key-source-of-truth.md` and
    /// `docs/adr/0009-secrets-live-in-a-synced-keychain-not-userdefaults.md`.
    private var providerAPIKeys: [AIProvider: String]

    /// Providers whose key the Secret Store refused to answer for at launch. Their
    /// mirrored value is empty, which is why it may never be mistaken for an unset key.
    private var unreadableProviders: Set<AIProvider>

    /// Providers whose local key the migration found already superseded by a differing
    /// one synced from another device. The synced key won; the Providers screen names
    /// them so a working key is never lost silently.
    private(set) var providersWithSupersededKeys: [AIProvider]

    /// The notice for the Providers screen, or `nil` once there is nothing to say.
    var supersededProviderKeysNotice: SupersededProviderKeysNotice? {
        SupersededProviderKeysNotice(providers: providersWithSupersededKeys)
    }

    /// Dismisses the superseded-keys notice; it does not return on a later launch.
    func acknowledgeSupersededProviderKeysNotice() {
        providersWithSupersededKeys = []
        userDefaults.removeObject(forKey: Keys.providersWithSupersededKeys)
    }

    // MARK: - AI Provider Keys

    /// The stored API key for an AI Provider (empty string if unset).
    func apiKey(for provider: AIProvider) -> String {
        providerAPIKeys[provider] ?? ""
    }

    /// Stores an AI Provider's API key — the single source of truth AI calls read.
    func setAPIKey(_ key: String, for provider: AIProvider) {
        providerAPIKeys[provider] = key
        writeKeyToStore(key, for: provider)
    }

    /// The key an AI call carries for `provider` — the stored one, or the fact that the
    /// Secret Store could not be read, which `apiKey(for:)` alone cannot express.
    func storedAPIKey(for provider: AIProvider) -> ProviderAPIKey {
        unreadableProviders.contains(provider) ? .unreadable : .stored(apiKey(for: provider))
    }

    /// Writes one provider's key through to the Secret Store. A refused write leaves the
    /// mirrored key in place, so the session the user pasted it in keeps working.
    private func writeKeyToStore(_ key: String, for provider: AIProvider) {
        do {
            try secretStore.setSecret(key, forKey: Self.apiKeyStorageKey(for: provider))
            unreadableProviders.remove(provider)
        } catch {
            Logger.settings.error("Secret Store write failed for \(provider.displayName): \(error)")
        }
    }

    /// Writes the Variables list through to the Secret Store as one item. A refused write
    /// leaves the mirrored list in place, so the session the user edited it in keeps working.
    private func writeVariablesToStore() {
        do {
            try secretStore.setSecret(Self.encodeVariables(mirroredVariables), forKey: Keys.variables)
            variablesUnreadable = false
        } catch {
            Logger.settings.error("Secret Store write failed for the Variables list: \(error)")
        }
    }

    /// Whether an AI Provider has a non-empty stored API key. A provider whose key the
    /// Secret Store refused counts as configured: an unreadable key cannot be told apart
    /// from an absent one, and dropping the provider out of the pickers would present the
    /// failure as an unset key instead of letting the run say the Store could not be read.
    func isProviderConfigured(_ provider: AIProvider) -> Bool {
        unreadableProviders.contains(provider) || !apiKey(for: provider).isEmpty
    }

    /// AI Providers with a non-empty stored API key, in `allCases` order.
    /// Mirrors iOS `AIProvider.configuredProviders` so the Mode picker offers
    /// only providers the user has actually set a key for.
    var configuredProviders: [AIProvider] {
        AIProvider.allCases.filter { isProviderConfigured($0) }
    }

    /// The AI Providers a Mode's provider picker should list: all configured
    /// providers, plus `selected` if it is currently unconfigured — so a Mode
    /// pinned to a now-unconfigured provider never shows a blank selection.
    func providerPickerOptions(selected: AIProvider) -> [AIProvider] {
        var options = configuredProviders
        if !options.contains(selected) {
            options.append(selected)
        }
        return options
    }

    /// Whether a mode is fully configured and ready to use.
    /// Cloud AI modes require the AI Provider's stored API key to be set.
    func isModeConfigured(_ mode: Mode) -> Bool {
        guard mode.processingType == .cloudAI else { return true }
        return isProviderConfigured(mode.aiProvider)
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
    private let secretStore: any SecretStore

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

        /// Names the Variables list's Secret Store item, and the UserDefaults entry the
        /// one-shot migration drains into it.
        static let variables = "variables"
        // Names each AI Provider key's Secret Store item, and the UserDefaults entry the
        // one-shot migration drains into it. iOS files its keys under the same names, so a
        // key pasted there matches the query made here.
        static let anthropicAPIKey = "ai_processing_anthropic_api_key"
        static let openaiAPIKey = "ai_processing_openai_api_key"
        static let geminiAPIKey = "ai_processing_gemini_api_key"
        /// Persisted flag gating the one-shot Reserved Variable → Provider key migration.
        static let didMigrateProviderKeys = "didMigrateProviderKeys"
        /// Persisted flag gating the one-shot Provider key → Secret Store migration.
        static let didMigrateProviderKeysToSecretStore = "didMigrateProviderKeysToSecretStore"
        /// Providers the Secret Store migration found already holding a differing key.
        static let providersWithSupersededKeys = "providersWithSupersededKeys"
        /// Persisted flag gating the one-shot Variables list → Secret Store migration.
        static let didMigrateVariablesToSecretStore = "didMigrateVariablesToSecretStore"
        static let removeFillerWords = "removeFillerWords"
        static let defaultTranscriptionModel = "defaultTranscriptionModel"
        static let transcriptionModelSettings = "transcriptionModelSettings"
        static let legacyPreferredInputDeviceID = "preferredInputDeviceID"
        static let legacyPushToTalkHotkey = "pushToTalkHotkey"
        static let legacyKeyCode = "hotkeyKeyCode"
        static let legacyModifiers = "hotkeyModifiers"
    }

    /// The name an AI Provider's API key is stored under: its Secret Store item, and
    /// the UserDefaults entry the one-shot migration drains into that item.
    private static func apiKeyStorageKey(for provider: AIProvider) -> String {
        switch provider {
        case .anthropic: Keys.anthropicAPIKey
        case .openai: Keys.openaiAPIKey
        case .gemini: Keys.geminiAPIKey
        }
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

    /// The model stored under `key`, or `defaultValue` when nothing is stored or
    /// what is stored names a model this build no longer has — a downgrade, or a
    /// model dropped from the enum, must leave the app with one it can run.
    private static func transcriptionModelSetting(
        from defaults: UserDefaults, forKey key: String, default defaultValue: TranscriptionModel
    ) -> TranscriptionModel {
        guard let raw = defaults.string(forKey: key),
              let model = TranscriptionModel(rawValue: raw) else { return defaultValue }
        return model
    }

    /// The Variables list as the one string its Secret Store item holds, and back. The
    /// Store's values are strings, so the array travels as the same JSON that used to sit
    /// in the preferences file.
    private static func encodeVariables(_ variables: [Variable]) -> String? {
        guard let data = try? JSONEncoder().encode(variables) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeVariables(from secret: String?) -> [Variable] {
        guard let secret, let data = secret.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Variable].self, from: data) else {
            return []
        }
        return decoded
    }

    private func encode<T: Codable>(_ value: T, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(value) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    init(userDefaults: UserDefaults = .standard, secretStore: any SecretStore) {
        self.userDefaults = userDefaults
        self.secretStore = secretStore

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
            removeFillerWords: Self.boolSetting(from: userDefaults, forKey: Keys.removeFillerWords, default: true),
            defaultModel: Self.transcriptionModelSetting(
                from: userDefaults,
                forKey: Keys.defaultTranscriptionModel,
                default: TranscriptionSettings.default.defaultModel
            ),
            modelSettings: Self.decodeSetting(
                from: userDefaults,
                forKey: Keys.transcriptionModelSettings,
                default: TranscriptionSettings.default.modelSettings
            )
        )

        // Load modes (with legacy migration)
        let loadedModes: [Mode]
        if let modesData = userDefaults.data(forKey: Keys.modes),
           let decoded = try? JSONDecoder().decode([Mode].self, from: modesData),
           !decoded.isEmpty {
            loadedModes = decoded
        } else {
            // Legacy migration: if an old user had a custom bash script configured,
            // preserve it as a user mode so their workflow isn't lost.
            let oldActionType = PostTranscriptionActionType(
                rawValue: userDefaults.string(forKey: "actionType") ?? ""
            ) ?? .paste
            let oldBashCommand = userDefaults.string(forKey: "bashCommand") ?? ""
            if oldActionType == .bash, !oldBashCommand.isEmpty {
                loadedModes = [Mode(
                    id: UUID(), name: "Bash Script",
                    processingType: .bashScript,
                    processingCommand: oldBashCommand
                )]
            } else {
                // Fresh install: start empty; refreshTemplateAvailability() seeds
                // the built-in templates (Transcription, Dictation, Assistant x2).
                loadedModes = []
            }
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

        // Load variables from the Secret Store — the list carries whatever secrets a bash
        // script needs, so it sits beside the Provider keys rather than in UserDefaults.
        do {
            self.mirroredVariables = Self.decodeVariables(from: try secretStore.secret(forKey: Keys.variables))
            self.variablesUnreadable = false
        } catch {
            self.mirroredVariables = []
            self.variablesUnreadable = true
            Logger.settings.error("Secret Store read failed for the Variables list: \(error)")
        }

        // Load AI Provider API keys from the Secret Store — the single source of truth
        // for AI calls. A provider the Store refused is remembered as unreadable, never
        // folded into the empty-key case.
        var loadedKeys: [AIProvider: String] = [:]
        var unreadable: Set<AIProvider> = []
        for provider in AIProvider.allCases {
            do {
                loadedKeys[provider] = try secretStore.secret(forKey: Self.apiKeyStorageKey(for: provider)) ?? ""
            } catch {
                loadedKeys[provider] = ""
                unreadable.insert(provider)
                Logger.settings.error("Secret Store read failed for \(provider.displayName): \(error)")
            }
        }
        self.providerAPIKeys = loadedKeys
        self.unreadableProviders = unreadable
        self.providersWithSupersededKeys = (userDefaults.stringArray(forKey: Keys.providersWithSupersededKeys) ?? [])
            .compactMap(AIProvider.init(rawValue:))

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

        // One-shot: move Provider keys out of UserDefaults into the Secret Store. Runs
        // first so the Reserved Variable migration below sees the keys it carried over.
        migrateProviderKeysToSecretStoreIfNeeded()

        // One-shot: move the Variables list out of UserDefaults into the Secret Store.
        // Runs before the Reserved Variable migration below, which reads the list.
        migrateVariablesToSecretStoreIfNeeded()

        // One-shot: fold legacy Reserved-named Variable rows into Provider keys.
        migrateReservedVariablesIfNeeded()
    }

    /// One-shot migration of each Provider key out of `UserDefaults` and into the Secret
    /// Store, gated by a persisted flag. A key is copied only where the Store holds nothing
    /// for that provider; where the Store already holds a differing key — one synced from
    /// another device — the stored key wins and the provider is recorded so the Providers
    /// screen can say so. The `UserDefaults` entry goes either way: nothing secret stays
    /// there. See `docs/adr/0009-secrets-live-in-a-synced-keychain-not-userdefaults.md`.
    private func migrateProviderKeysToSecretStoreIfNeeded() {
        guard !userDefaults.bool(forKey: Keys.didMigrateProviderKeysToSecretStore) else { return }
        // A Store that would not answer is indistinguishable from an empty one, and acting
        // on that guess would overwrite a synced key. Leave everything and retry next launch.
        guard unreadableProviders.isEmpty else { return }

        var superseded: [AIProvider] = []
        for provider in AIProvider.allCases {
            let storageKey = Self.apiKeyStorageKey(for: provider)
            let carried = userDefaults.string(forKey: storageKey) ?? ""
            if !carried.isEmpty {
                let stored = apiKey(for: provider)
                if stored.isEmpty {
                    do {
                        try secretStore.setSecret(carried, forKey: storageKey)
                    } catch {
                        // Dropping the entry now would lose the key. Abandon the run with
                        // the flag unset; the providers already migrated stay migrated.
                        Logger.settings.error("Secret Store migration failed for \(provider.displayName): \(error)")
                        return
                    }
                    providerAPIKeys[provider] = carried
                } else if stored != carried {
                    superseded.append(provider)
                }
            }
            userDefaults.removeObject(forKey: storageKey)
        }

        providersWithSupersededKeys = superseded
        userDefaults.set(superseded.map(\.rawValue), forKey: Keys.providersWithSupersededKeys)
        userDefaults.set(true, forKey: Keys.didMigrateProviderKeysToSecretStore)
        Logger.settings.info("Provider keys migrated to the Secret Store; superseded: \(superseded.count)")
    }

    /// One-shot migration of the Variables list out of `UserDefaults` and into the Secret
    /// Store, gated by a persisted flag. The list is carried over only where the Store holds
    /// none; a list already synced from another device wins, unnoticed, because a merge of
    /// two name/value lists has no answer the user would recognise. The `UserDefaults` entry
    /// goes either way: nothing secret stays there.
    private func migrateVariablesToSecretStoreIfNeeded() {
        guard !userDefaults.bool(forKey: Keys.didMigrateVariablesToSecretStore) else { return }
        // A Store that would not answer is indistinguishable from one holding no list, and
        // acting on that guess would overwrite a synced list. Retry next launch instead.
        guard !variablesUnreadable else { return }

        let carried: [Variable] = Self.decodeSetting(from: userDefaults, forKey: Keys.variables, default: [])
        if !carried.isEmpty, mirroredVariables.isEmpty {
            do {
                try secretStore.setSecret(Self.encodeVariables(carried), forKey: Keys.variables)
            } catch {
                // Dropping the entry now would lose the list. Abandon the run with the flag
                // unset so the next launch tries again.
                Logger.settings.error("Secret Store migration failed for the Variables list: \(error)")
                return
            }
            mirroredVariables = carried
        }

        userDefaults.removeObject(forKey: Keys.variables)
        userDefaults.set(true, forKey: Keys.didMigrateVariablesToSecretStore)
        Logger.settings.info("Variables list migrated to the Secret Store")
    }

    /// One-shot migration of legacy Reserved-named Variable rows (`ANTHROPIC_API_KEY`,
    /// etc.) into the matching Provider key, then drops the rows. Gated by a persisted
    /// flag so it runs exactly once. A non-empty Reserved Variable is copied into the
    /// Provider key only when that key is still empty; if both already hold a value the
    /// row is left as an explicit bash override. Empty Reserved rows (the formerly
    /// auto-created blanks) are dropped. See ADR-0001.
    private func migrateReservedVariablesIfNeeded() {
        guard !userDefaults.bool(forKey: Keys.didMigrateProviderKeys) else { return }

        let reservedByName = Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map { ($0.apiKeyVariableName, $0) }
        )
        var remaining: [Variable] = []
        for variable in variables {
            guard let provider = reservedByName[variable.name] else {
                remaining.append(variable)
                continue
            }
            if variable.value.isEmpty {
                // Empty Reserved Variable is unset (falls back to the Provider key) — drop it.
                continue
            }
            if apiKey(for: provider).isEmpty {
                // Seed the still-empty Provider key, then drop the row.
                setAPIKey(variable.value, for: provider)
                continue
            }
            // Both a Provider key and a non-empty Reserved Variable exist — leave both.
            remaining.append(variable)
        }
        variables = remaining
        userDefaults.set(true, forKey: Keys.didMigrateProviderKeys)
        save()
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
        userDefaults.set(transcriptionSettings.removeFillerWords, forKey: Keys.removeFillerWords)
        userDefaults.set(transcriptionSettings.defaultModel.rawValue, forKey: Keys.defaultTranscriptionModel)
        encode(transcriptionSettings.modelSettings, forKey: Keys.transcriptionModelSettings)
        Logger.settings.info("Settings saved")
    }

    /// Creates template modes for newly available tools and refreshes availability state.
    func refreshTemplateAvailability() async {
        modeConfig.availableTemplateIDs = await ToolAvailabilityChecker.checkAll()

        // Migrate legacy "dictation" template to "plain"
        for i in modeConfig.modes.indices where modeConfig.modes[i].templateID == "dictation" {
            modeConfig.modes[i].templateID = "plain"
            Logger.settings.info("Migrated dictation template mode to plain")
        }

        // Align plain-template mode names with the current default ("Verbatim").
        // Covers legacy "Dictation", intermediate "Plain", and prior "Transcription".
        for i in modeConfig.modes.indices where modeConfig.modes[i].templateID == "plain" {
            let currentName = modeConfig.modes[i].name
            if currentName == "Dictation" || currentName == "Plain" || currentName == "Transcription" {
                modeConfig.modes[i].name = "Verbatim"
            }
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
