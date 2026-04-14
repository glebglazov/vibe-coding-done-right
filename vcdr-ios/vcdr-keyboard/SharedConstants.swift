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

    // Shared AI/style preferences (keyboard ↔ app)
    static let settingsNotificationName = "glebglazov.vcdr-ios.settingsChanged"
    static let aiActiveKey = "shared_ai_active"
    static let aiModeKey = "shared_ai_mode"
    static let textStyleKey = "shared_text_style"
    static let aiConfiguredKey = "shared_ai_configured"

    // Selected text capture (keyboard → app) — written before recording starts in assistant mode
    static let selectedTextKey = "shared_selected_text"

    // Multi-capture (keyboard → app) — JSON array of captured text selections in assistant mode
    static let capturedTextsKey = "shared_captured_texts"

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
    case dictation
    case assistant

    var displayName: String {
        switch self {
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
enum SharedTextStyle: String {
    case casual
    case formal

    var displayName: String {
        switch self {
        case .casual: "Casual"
        case .formal: "Formal"
        }
    }

    var toggled: SharedTextStyle {
        self == .casual ? .formal : .casual
    }
}
