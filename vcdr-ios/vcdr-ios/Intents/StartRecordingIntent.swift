import AppIntents

/// As an `AudioRecordingIntent` it starts audio while VCDR stays in the
/// background. AppIntents then requires a Live Activity, and only a
/// `LiveActivityIntent` may request one from the background.
struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts a VCDR recording.")

    @AppDependency private var remote: any RecordingRunRemote

    init() {}

    func perform() async throws -> some IntentResult {
        try await remote.startFromShortcut()
        return .result()
    }
}
