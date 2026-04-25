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

    // Settings — two disjoint tiers. See the iOS SharedConstants for the full
    // contract: default_* is written by the Settings UI via DefaultSettings,
    // session_* is written by cycle paths via SessionSettings, and consumers
    // read effective values from SessionSettings.
    static let defaultTextStyleKey = "default_text_style"
    static let defaultAIModeKey    = "default_ai_mode"
    static let defaultAIActiveKey  = "default_ai_active"
    static let sessionTextStyleKey = "session_text_style"
    static let sessionAIModeKey    = "session_ai_mode"
    static let sessionAIActiveKey  = "session_ai_active"

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
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
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

/// Keyboard-side mirror of SessionSettings in the main app. Only touches
/// `session_*` keys — there is intentionally no API here that can write
/// `default_*`, so the keyboard can never overwrite the user's configured
/// defaults from the Settings UI.
enum SessionSettings {
    // MARK: - Writers

    static func setTextStyle(_ value: SharedTextStyle) {
        write { $0.set(value.rawValue, forKey: SharedConstants.sessionTextStyleKey) }
    }

    static func setAIMode(_ value: SharedAIMode) {
        write { $0.set(value.rawValue, forKey: SharedConstants.sessionAIModeKey) }
    }

    static func setAIActive(_ active: Bool) {
        write { $0.set(active, forKey: SharedConstants.sessionAIActiveKey) }
    }

    // MARK: - Readers (effective: session ?? default ?? fallback)

    static func effectiveTextStyle() -> SharedTextStyle {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.sessionTextStyleKey)
            ?? sd.string(forKey: SharedConstants.defaultTextStyleKey)
            ?? ""
        return SharedTextStyle(rawValue: raw) ?? .casual
    }

    static func effectiveAIMode() -> SharedAIMode {
        let sd = SharedConstants.sharedDefaults
        let raw = sd.string(forKey: SharedConstants.sessionAIModeKey)
            ?? sd.string(forKey: SharedConstants.defaultAIModeKey)
            ?? ""
        return SharedAIMode(rawValue: raw) ?? .verbatim
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
