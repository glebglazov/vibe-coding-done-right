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
