#if os(iOS)
import AppIntents

/// How an App Intent reaches the app's Recording Run. It lives beside the card
/// because the widget compiles `StopRecordingIntent` to build its button. Only
/// the app registers a conformer, and only the app process runs `perform()`.
@MainActor
protocol RecordingRunRemote: AnyObject, Sendable {
    /// Returns once a start reaches Capturing with its card, or ends, or once
    /// a stop has been handed to the run.
    func toggleFromShortcut() async throws(RecordingRemoteRefusal)
    /// Never starts a run.
    func stopFromCard() async
}

nonisolated enum RecordingRemoteRefusal: Error, CustomLocalizedStringResourceConvertible {
    /// The permission prompt cannot appear while VCDR is in the background.
    case microphoneNotAllowed
    /// The system stops a background recording that has no Live Activity.
    case liveActivitiesOff
    /// ActivityKit refused the card, so the run was discarded before the
    /// system could stop it halfway.
    case cardUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .microphoneNotAllowed: "Open VCDR once to allow microphone access."
        case .liveActivitiesOff: "Turn on Live Activities for VCDR in Settings."
        case .cardUnavailable: "VCDR couldn't show its recording card. Try again."
        }
    }
}
#endif
