import Foundation

enum SharedConstants {
    static let appGroupID = "group.glebglazov.vcdr-ios"

    // Commands (keyboard → app)
    static let commandKey = "command"
    static let commandNotificationName = "glebglazov.vcdr-ios.command"

    // Recording state (app → keyboard) — also carries transcription text via state bundling ("idle|text")
    static let stateKey = "recordingState"
    static let stateNotificationName = "glebglazov.vcdr-ios.stateChanged"

    // Deep link URLs
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!

    // Settings — two disjoint tiers. Never copy one tier into the other.
    //
    //   default_*  — user-configured defaults. Written by Settings UI only via
    //                DefaultSettings. Survive across launches.
    //   session_*  — per-session cycle overrides. Written by cycle paths via
    //                SessionSettings. Cleared on cold launch.
    //
    // Consumers always read the effective value (session ?? default ?? fallback)
    // via SessionSettings.effective…(). There is intentionally no API that can
    // overwrite session state with default values — the bug that motivated this
    // split ("app background resets cycled style to configured default") is
    // unrepresentable when defaults and sessions live in different keys.
    static let defaultTextStyleKey = "default_text_style"
    static let defaultAIModeKey    = "default_ai_mode"
    static let defaultAIActiveKey  = "default_ai_active"
    static let sessionTextStyleKey = "session_text_style"
    static let sessionAIModeKey    = "session_ai_mode"
    static let sessionAIActiveKey  = "session_ai_active"

    /// Whether the custom keyboard should fire haptic feedback. Absent → treat
    /// as enabled (the default). Written by the Settings UI via `DefaultSettings`.
    static let defaultKeyboardHapticsEnabledKey = "default_keyboard_haptics_enabled"

    static let settingsNotificationName = "glebglazov.vcdr-ios.settingsChanged"
    static let aiConfiguredKey = "shared_ai_configured"

    // Selected text capture (keyboard → app) — written before recording starts in assistant mode
    static let selectedTextKey = "shared_selected_text"

    // Multi-capture (keyboard → app) — JSON array of captured text selections in assistant mode
    static let capturedTextsKey = "shared_captured_texts"

    /// App → keyboard heartbeat (Double, `timeIntervalSince1970`). Refreshed
    /// periodically while the hot session is alive and on state changes. The
    /// keyboard reads this before deciding whether to try a Darwin command
    /// (app alive → fast in-keyboard path) or fall back to the URL scheme
    /// (app suspended/killed → foreground-and-record bounce).
    static let appHeartbeatKey = "app_heartbeat_at"

    /// Shared UserDefaults for App Group IPC between main app and keyboard extension.
    /// Falls back to `.standard` if the App Group is unavailable (e.g. unit tests,
    /// misconfigured signing) — prevents a crash at the cost of IPC not working.
    static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: appGroupID) ?? .standard
}

/// Commands the keyboard extension sends to the main app
enum RecordingCommand: String {
    case startRecording
    case stopRecording
}

/// Recording states the main app publishes for the keyboard extension to read
enum RecordingState: String {
    case idle
    case recording
    case transcribing
    case emptyResult
}

/// AI prompt mode — keyboard-safe mirror of AIPromptMode.
/// Raw values must match AIPromptMode in the main app.
enum SharedAIMode: String {
    case verbatim
    case dictation
    case assistant

    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .dictation: "Dictation"
        case .assistant: "Assistant"
        }
    }

    var next: SharedAIMode {
        self == .dictation ? .assistant : .dictation
    }
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
/// Every write also clears the matching session override so the new default
/// takes effect immediately for the live session.
enum DefaultSettings {
    static func setTextStyle(_ value: TextStyle) {
        write { sd in
            sd.set(value.rawValue, forKey: SharedConstants.defaultTextStyleKey)
            sd.removeObject(forKey: SharedConstants.sessionTextStyleKey)
        }
    }

    static func setAIMode(_ value: AIPromptMode) {
        write { sd in
            sd.set(value.rawValue, forKey: SharedConstants.defaultAIModeKey)
            sd.removeObject(forKey: SharedConstants.sessionAIModeKey)
        }
    }

    static func setAIActive(_ active: Bool) {
        write { sd in
            sd.set(active, forKey: SharedConstants.defaultAIActiveKey)
            sd.removeObject(forKey: SharedConstants.sessionAIActiveKey)
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

/// Writes per-session cycle overrides and reads the effective value that
/// consumers should act on: `session ?? default ?? hardcoded fallback`.
///
/// Session keys are stored under `session_*` and never share storage with
/// defaults (`default_*`), so no write path here can clobber a user's
/// configured default, and no write path on `DefaultSettings` can clobber a
/// live cycle choice (beyond the intentional clear-on-default-change).
enum SessionSettings {
    // MARK: - Writers

    static func setTextStyle(_ value: TextStyle) {
        write { $0.set(value.rawValue, forKey: SharedConstants.sessionTextStyleKey) }
    }

    static func setAIMode(_ value: AIPromptMode) {
        write { $0.set(value.rawValue, forKey: SharedConstants.sessionAIModeKey) }
    }

    static func setAIActive(_ active: Bool) {
        write { $0.set(active, forKey: SharedConstants.sessionAIActiveKey) }
    }

    /// Drops every per-session override. Call on cold launch so a new run
    /// starts from configured defaults rather than the last run's overrides.
    static func clearAll() {
        write { sd in
            sd.removeObject(forKey: SharedConstants.sessionTextStyleKey)
            sd.removeObject(forKey: SharedConstants.sessionAIModeKey)
            sd.removeObject(forKey: SharedConstants.sessionAIActiveKey)
        }
    }

    // MARK: - Readers (effective: session ?? default ?? fallback)

    static func effectiveTextStyle() -> TextStyle {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.sessionTextStyleKey)
            ?? sd.string(forKey: SharedConstants.defaultTextStyleKey)
            ?? ""
        return TextStyle(rawValue: raw) ?? .casual
    }

    static func effectiveAIMode() -> AIPromptMode {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.sessionAIModeKey)
            ?? sd.string(forKey: SharedConstants.defaultAIModeKey)
            ?? ""
        return AIPromptMode(rawValue: raw) ?? .verbatim
    }

    static func effectiveAIActive() -> Bool {
        let sd = SharedConstants.sharedDefaults
        if sd.object(forKey: SharedConstants.sessionAIActiveKey) != nil {
            return sd.bool(forKey: SharedConstants.sessionAIActiveKey)
        }
        if sd.object(forKey: SharedConstants.defaultAIActiveKey) != nil {
            return sd.bool(forKey: SharedConstants.defaultAIActiveKey)
        }
        return false
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
    private static let legacySharedAIActiveKey = "shared_ai_active"
    private static let legacySharedAIModeKey = "shared_ai_mode"
    private static let legacySharedTextStyleKey = "shared_text_style"

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
        if sd.object(forKey: SharedConstants.defaultAIActiveKey) == nil,
           std.object(forKey: legacyActiveInDictationKey) != nil {
            sd.set(std.bool(forKey: legacyActiveInDictationKey), forKey: SharedConstants.defaultAIActiveKey)
        }

        // The old "live" keys in sharedDefaults no longer mean anything —
        // they were both the source of truth for cycles and the clobber
        // target of `syncAll`. Drop them so stale values can't leak in.
        sd.removeObject(forKey: legacySharedAIActiveKey)
        sd.removeObject(forKey: legacySharedAIModeKey)
        sd.removeObject(forKey: legacySharedTextStyleKey)

        sd.synchronize()
    }
}
