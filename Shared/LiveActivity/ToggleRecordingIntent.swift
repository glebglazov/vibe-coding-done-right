#if os(iOS)
import AppIntents

/// "Toggle Recording". As an `AudioRecordingIntent` it starts audio while VCDR
/// stays in the background. The final text goes to the clipboard and to
/// history, and nothing returns to Shortcuts.
struct ToggleRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription(
        "Starts a VCDR recording, or stops the current one and copies the text."
    )

    @AppDependency private var remote: any RecordingRunRemote

    init() {}

    func perform() async throws -> some IntentResult {
        try await remote.toggleFromShortcut()
        return .result()
    }
}
#endif
