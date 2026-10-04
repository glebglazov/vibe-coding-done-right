#if os(iOS)
import AppIntents

/// The Mic Presence card's Stop button. As a `LiveActivityIntent` it runs in
/// the app process, where the remote is registered; the widget only uses the
/// type to build the button.
struct StopFromCardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let isDiscoverable = false

    @AppDependency private var remote: any RecordingRunRemote

    init() {}

    func perform() async throws -> some IntentResult {
        await remote.stopFromCard()
        return .result()
    }
}
#endif
