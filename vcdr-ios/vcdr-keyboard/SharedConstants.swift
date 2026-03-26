import Foundation

enum SharedConstants {
    static let appGroupID = "group.glebglazov.vcdr-ios"

    // Transcription result (app → keyboard)
    static let transcriptionResultKey = "pendingTranscription"
    static let transcriptionNotificationName = "glebglazov.vcdr-ios.transcriptionReady"

    // Host app detection — keyboard writes the host bundle ID here
    static let hostBundleIDKey = "hostBundleID"

    // Commands (keyboard → app)
    static let commandKey = "command"
    static let commandNotificationName = "glebglazov.vcdr-ios.command"

    // Recording state (app → keyboard)
    static let stateKey = "recordingState"
    static let stateNotificationName = "glebglazov.vcdr-ios.stateChanged"

    // Audio session state — keyboard reads this to decide if flash is needed
    static let audioSessionActiveKey = "audioSessionActive"

    // Deep link URLs
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
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
}
