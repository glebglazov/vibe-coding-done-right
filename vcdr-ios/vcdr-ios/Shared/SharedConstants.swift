import Foundation

enum SharedConstants {
    static let appGroupID = "group.glebglazov.vcdr-ios"

    // Settings — two disjoint tiers. Never copy one tier into the other.
    //
    //   default_*  — user-configured defaults. Written by Settings UI only via
    //                DefaultSettings. Survive across launches.
    //   session_*  — Setting Overrides, the user's cycled picks. Written by
    //                cycle paths via SettingOverrides. Survive across launches;
    //                cleared when the matching default changes. The prefix is
    //                the name they were first stored under, kept so no pick is
    //                lost on update.
    //
    // Consumers always read the effective value (override ?? default ?? fallback)
    // via SettingOverrides.effective…(). There is intentionally no API that can
    // overwrite an override with default values — the bug that motivated this
    // split ("app background resets cycled style to configured default") is
    // unrepresentable when defaults and overrides live in different keys.
    static let defaultTextStyleKey = "default_text_style"
    static let defaultAIModeKey    = "default_ai_mode"
    static let textStyleOverrideKey = "session_text_style"
    static let aiModeOverrideKey    = "session_ai_mode"

    /// Whether the custom keyboard should fire haptic feedback. Absent → treat
    /// as enabled (the default). Written by the Settings UI via `DefaultSettings`.
    static let defaultKeyboardHapticsEnabledKey = "default_keyboard_haptics_enabled"

    static let settingsNotificationName = "glebglazov.vcdr-ios.settingsChanged"
    static let aiConfiguredKey = "shared_ai_configured"

    /// Shared UserDefaults for App Group IPC between main app and keyboard extension.
    /// Falls back to `.standard` if the App Group is unavailable (e.g. unit tests,
    /// misconfigured signing) — prevents a crash at the cost of IPC not working.
    static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: appGroupID) ?? .standard
}

/// Text style — keyboard-safe mirror of TextStyle.
/// Raw values must match TextStyle in the main app.
enum SharedTextStyle: String, CaseIterable {
    case casual
    case messaging
    case formal

    var displayName: String {
        switch self {
        case .casual: "Casual"
        case .messaging: "Messaging"
        case .formal: "Formal"
        }
    }

    /// Next style in a circular cycle, in `allCases` order.
    var next: SharedTextStyle {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// Writes user-configured defaults. The Settings UI is the only intended caller.
///
/// Every write also clears the matching Setting Override so the new default
/// takes effect immediately.
enum DefaultSettings {
    static func setTextStyle(_ value: TextStyle) {
        write { sd in
            sd.set(value.rawValue, forKey: SharedConstants.defaultTextStyleKey)
            sd.removeObject(forKey: SharedConstants.textStyleOverrideKey)
        }
    }

    static func setAIMode(_ value: AIPromptMode) {
        write { sd in
            sd.set(value.rawValue, forKey: SharedConstants.defaultAIModeKey)
            sd.removeObject(forKey: SharedConstants.aiModeOverrideKey)
        }
    }

    static func setAIConfigured(_ configured: Bool) {
        write { $0.set(configured, forKey: SharedConstants.aiConfiguredKey) }
    }

    static func setKeyboardHapticsEnabled(_ enabled: Bool) {
        write { $0.set(enabled, forKey: SharedConstants.defaultKeyboardHapticsEnabledKey) }
    }

    private static func write(_ block: (UserDefaults) -> Void) {
        let sd = SharedConstants.sharedDefaults
        block(sd)
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.settingsNotificationName)
    }
}

/// Writes Setting Overrides and reads the effective value that consumers
/// should act on: `override ?? default ?? hardcoded fallback`.
///
/// Overrides are stored under `session_*` and never share storage with
/// defaults (`default_*`), so no write path here can clobber a user's
/// configured default, and no write path on `DefaultSettings` can clobber a
/// live cycle choice (beyond the intentional clear-on-default-change).
enum SettingOverrides {
    // MARK: - Writers

    static func setTextStyle(_ value: TextStyle) {
        write { $0.set(value.rawValue, forKey: SharedConstants.textStyleOverrideKey) }
    }

    static func setAIMode(_ value: AIPromptMode) {
        write { $0.set(value.rawValue, forKey: SharedConstants.aiModeOverrideKey) }
    }

    /// Drops every Setting Override, so every reader falls back to the
    /// configured defaults.
    static func clearAll() {
        write { sd in
            sd.removeObject(forKey: SharedConstants.textStyleOverrideKey)
            sd.removeObject(forKey: SharedConstants.aiModeOverrideKey)
        }
    }

    // MARK: - Readers (effective: session ?? default ?? fallback)

    static func effectiveTextStyle() -> TextStyle {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.textStyleOverrideKey)
            ?? sd.string(forKey: SharedConstants.defaultTextStyleKey)
            ?? ""
        return TextStyle(rawValue: raw) ?? .casual
    }

    static func effectiveAIMode() -> AIPromptMode {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.aiModeOverrideKey)
            ?? sd.string(forKey: SharedConstants.defaultAIModeKey)
            ?? ""
        return AIPromptMode(rawValue: raw) ?? .verbatim
    }

    private static func write(_ block: (UserDefaults) -> Void) {
        let sd = SharedConstants.sharedDefaults
        block(sd)
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.settingsNotificationName)
    }
}

/// One-shot migration from the pre-split layout where defaults lived in
/// `UserDefaults.standard` and live state lived in `sharedDefaults` under the
/// same bucket of keys. Runs at app launch; idempotent after the first run.
enum LegacySettingsMigrator {
    private static let legacyDefaultStyleKey = "text_style_default"
    private static let legacyDefaultModeKey = "ai_processing_default_mode"
    private static let legacyActiveInDictationKey = "ai_processing_active_in_dictation"
    private static let legacyDefaultAIActiveKey = "default_ai_active"
    private static let legacySessionAIActiveKey = "session_ai_active"
    private static let legacySharedAIActiveKey = "shared_ai_active"
    private static let legacySharedAIModeKey = "shared_ai_mode"
    private static let legacySharedTextStyleKey = "shared_text_style"

    /// The retired Assistant mode's stored id and the keys only it used.
    static let retiredAssistantModeID = "assistant"
    private static let retiredAssistantSharedKeys = [
        "shared_selected_text",
        "shared_captured_texts",
    ]
    private static let retiredAssistantStandardKeys = [
        "ai_processing_assistant_provider",
        "ai_processing_assistant_afm_fallback",
        "transcription_mode_override_assistant",
        "cachedPrompt_assistant",
    ]

    static func migrateIfNeeded() {
        let sd = SharedConstants.sharedDefaults
        let std = UserDefaults.standard

        if sd.object(forKey: SharedConstants.defaultTextStyleKey) == nil,
           let raw = std.string(forKey: legacyDefaultStyleKey) {
            sd.set(raw, forKey: SharedConstants.defaultTextStyleKey)
        }
        if sd.object(forKey: SharedConstants.defaultAIModeKey) == nil,
           let raw = std.string(forKey: legacyDefaultModeKey) {
            sd.set(raw, forKey: SharedConstants.defaultAIModeKey)
        }

        // Pre-rev: "AI off" was a separate boolean (`default_ai_active=false`)
        // that overrode the mode picker. The mode picker now owns that state
        // via `.verbatim`, so collapse the boolean into the mode and drop it.
        // Any stored mode wins; only force `.verbatim` when the boolean was
        // explicitly false and the user never picked a mode.
        if sd.object(forKey: legacyDefaultAIActiveKey) != nil {
            let wasActive = sd.bool(forKey: legacyDefaultAIActiveKey)
            if !wasActive, sd.object(forKey: SharedConstants.defaultAIModeKey) == nil {
                sd.set(AIPromptMode.verbatim.rawValue, forKey: SharedConstants.defaultAIModeKey)
            }
            sd.removeObject(forKey: legacyDefaultAIActiveKey)
        }
        sd.removeObject(forKey: legacySessionAIActiveKey)
        std.removeObject(forKey: legacyActiveInDictationKey)

        // The old "live" keys in sharedDefaults no longer mean anything —
        // they were both the source of truth for cycles and the clobber
        // target of `syncAll`. Drop them so stale values can't leak in.
        sd.removeObject(forKey: legacySharedAIActiveKey)
        sd.removeObject(forKey: legacySharedAIModeKey)
        sd.removeObject(forKey: legacySharedTextStyleKey)

        retireAssistantMode(shared: sd, standard: std)

        sd.synchronize()
    }

    /// A saved Assistant becomes AI on, the nearest mode that still calls AI.
    /// Without this step the reader falls back to AI off without a word.
    private static func retireAssistantMode(shared sd: UserDefaults, standard std: UserDefaults) {
        for key in [SharedConstants.defaultAIModeKey, SharedConstants.aiModeOverrideKey]
        where sd.string(forKey: key) == retiredAssistantModeID {
            sd.set(AIPromptMode.dictation.rawValue, forKey: key)
        }
        retiredAssistantSharedKeys.forEach(sd.removeObject(forKey:))
        retiredAssistantStandardKeys.forEach(std.removeObject(forKey:))
    }
}
