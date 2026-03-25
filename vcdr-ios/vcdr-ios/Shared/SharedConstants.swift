import Foundation

enum SharedConstants {
    static let appGroupID = "group.glebglazov.vcdr-ios"

    // Keyboard → App commands
    static let commandKey = "command"
    static let commandNotificationName = "glebglazov.vcdr-ios.command"

    // App → Keyboard state
    static let stateKey = "recordingState"
    static let stateNotificationName = "glebglazov.vcdr-ios.stateChanged"

    // App → Keyboard transcription result
    static let transcriptionResultKey = "pendingTranscription"
    static let transcriptionNotificationName = "glebglazov.vcdr-ios.transcriptionReady"

    // Audio session state (read by keyboard to decide Link vs Button)
    static let audioSessionActiveKey = "audioSessionActive"

    // Deep link URLs
    static let activateDeepLinkURL = URL(string: "vcdr-ios://activate")!
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }
}

enum RecordingCommand: String {
    case startRecording
    case stopRecording
}

enum RecordingState: String {
    case idle
    case recording
    case transcribing
}
