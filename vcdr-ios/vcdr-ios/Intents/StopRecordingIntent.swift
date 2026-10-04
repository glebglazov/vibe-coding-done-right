import AppIntents

/// Returns the text so a Shortcut can copy it: iOS refuses VCDR's own
/// clipboard write while VCDR is in the background.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription(
        "Stops the current VCDR recording and returns its text."
    )

    @AppDependency private var remote: any RecordingRunRemote

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await remote.stopFromShortcut())
    }
}
