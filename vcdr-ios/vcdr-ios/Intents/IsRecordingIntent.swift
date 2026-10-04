import AppIntents

/// Lets one Shortcut choose between Start Recording and Stop Recording with an
/// If action, so one button both starts and stops a run.
struct IsRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Recording"
    static let description = IntentDescription("Tells whether VCDR is recording now.")

    @AppDependency private var remote: any RecordingRunRemote

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: await remote.isRecording)
    }
}
