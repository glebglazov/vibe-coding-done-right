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
    static let stopDeepLinkURL = URL(string: "vcdr-ios://stop")!

    // Settings — two disjoint tiers. See the iOS SharedConstants for the full
    // contract: default_* is written by the Settings UI via DefaultSettings,
    // session_* holds Setting Overrides written via SettingOverrides, and consumers
    // read effective values from SettingOverrides.
    static let defaultTextStyleKey = "default_text_style"
    static let defaultAIModeKey    = "default_ai_mode"
    static let textStyleOverrideKey = "session_text_style"
    static let aiModeOverrideKey    = "session_ai_mode"

    /// Mirror of the app-side key. Absent → treat as enabled.
    static let defaultKeyboardHapticsEnabledKey = "default_keyboard_haptics_enabled"

    static let settingsNotificationName = "glebglazov.vcdr-ios.settingsChanged"
    static let aiConfiguredKey = "shared_ai_configured"

    /// App → keyboard heartbeat (Double, `timeIntervalSince1970`). Refreshed
    /// periodically while the hot session is alive and on state changes. The
    /// keyboard reads this before deciding whether to try a Darwin command
    /// (app alive → fast in-keyboard path) or fall back to the URL scheme
    /// (app suspended/killed → foreground-and-record bounce).
    static let appHeartbeatKey = "app_heartbeat_at"

    /// Keyboard display mode (Compact/Full) — keyboard-local UI state, never
    /// read by the app. Absent key → Compact, so fresh installs and installs
    /// that predate the key both land in Compact on the next keyboard open.
    static let keyboardDisplayModeKey = "keyboard_display_mode"

    /// Shared UserDefaults for App Group IPC between main app and keyboard extension.
    /// Falls back to `.standard` if the App Group is unavailable (e.g. unit tests,
    /// misconfigured signing) — prevents a crash at the cost of IPC not working.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

/// Commands the keyboard extension sends to the main app
enum RecordingCommand: String {
    case startRecording
    case stopRecording
}

/// Recording states the main app publishes for the keyboard extension to read.
/// One value per Recording Run terminal state, so the keyboard never infers a
/// terminal state from idle (ADR-0004). `failed` carries the failure reason
/// appended after `|`, the way `idle` carries the Bundled Result.
///
/// **This enum is duplicated in the app target's `SharedConstants.swift`. Both
/// copies must carry the same cases**: a mismatch fails silently, because each
/// side falls back to `UserDefaults.standard` when the App Group is unavailable.
enum RecordingState: String {
    case idle
    case recording
    case transcribing
    case emptyResult
    case cancelled
    case failed
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

/// The keyboard's two presentation states. Switching between them is a flag
/// flip in the live keyboard process — the keys are already built and come
/// back instantly — never a reload.
enum KeyboardDisplayMode: String {
    /// Dictation controls only, no key rows. The default state.
    case compact
    /// Key rows plus the toolbar strip.
    case full
}

/// Persists the chosen `KeyboardDisplayMode` across appearances, host apps,
/// and process teardown. Keyboard-local: no Darwin notification on write,
/// because the app never reads this value and waking it for a keyboard-only
/// visual flip would be wasted work.
enum KeyboardDisplayModeStore {
    /// The persisted mode. Absent or unreadable key → `.compact`.
    static func current() -> KeyboardDisplayMode {
        let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.keyboardDisplayModeKey) ?? ""
        return KeyboardDisplayMode(rawValue: raw) ?? .compact
    }

    static func set(_ mode: KeyboardDisplayMode) {
        let sd = SharedConstants.sharedDefaults
        sd.set(mode.rawValue, forKey: SharedConstants.keyboardDisplayModeKey)
        sd.synchronize()
    }
}

/// Keyboard-side mirror of SettingOverrides in the main app. Only touches
/// `session_*` keys — there is intentionally no API here that can write
/// `default_*`, so the keyboard can never overwrite the user's configured
/// defaults from the Settings UI.
enum SettingOverrides {
    // MARK: - Writers

    static func setTextStyle(_ value: SharedTextStyle) {
        write { $0.set(value.rawValue, forKey: SharedConstants.textStyleOverrideKey) }
    }

    static func setAIMode(_ value: AIPromptMode) {
        write { $0.set(value.rawValue, forKey: SharedConstants.aiModeOverrideKey) }
    }

    // MARK: - Readers (effective: session ?? default ?? fallback)

    static func effectiveTextStyle() -> SharedTextStyle {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.textStyleOverrideKey)
            ?? sd.string(forKey: SharedConstants.defaultTextStyleKey)
            ?? ""
        return SharedTextStyle(rawValue: raw) ?? .casual
    }

    static func effectiveAIMode() -> AIPromptMode {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.aiModeOverrideKey)
            ?? sd.string(forKey: SharedConstants.defaultAIModeKey)
            ?? ""
        return AIPromptMode(rawValue: raw) ?? .verbatim
    }

    /// Default-only setting (no Setting Override). Absent key → treat as enabled.
    static func effectiveKeyboardHapticsEnabled() -> Bool {
        let sd = SharedConstants.sharedDefaults
        if sd.object(forKey: SharedConstants.defaultKeyboardHapticsEnabledKey) != nil {
            return sd.bool(forKey: SharedConstants.defaultKeyboardHapticsEnabledKey)
        }
        return true
    }

    private static func write(_ block: (UserDefaults) -> Void) {
        let sd = SharedConstants.sharedDefaults
        block(sd)
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.settingsNotificationName)
    }
}
