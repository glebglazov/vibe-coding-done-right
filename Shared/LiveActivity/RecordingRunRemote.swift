#if os(iOS)
import AppIntents

/// How an App Intent reaches the app's Recording Run. It lives beside the card
/// because the widget compiles the intents that use it to build its buttons.
/// Only the app registers a conformer, and only the app process runs `perform()`.
@MainActor
protocol RecordingRunRemote: AnyObject, Sendable {
    /// Returns once a start reaches Capturing with its card, or ends, or once
    /// a stop has been handed to the run.
    func toggleFromShortcut() async throws(RecordingRemoteRefusal)
    /// Never starts a run.
    func stopFromCard() async
}

nonisolated enum RecordingRemoteRefusal: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The permission prompt cannot appear while VCDR is in the background.
    case microphoneNotAllowed
    /// The system stops a background recording that has no Live Activity.
    case liveActivitiesOff
    /// ActivityKit refused the card, so the run was discarded before the
    /// system could stop it halfway.
    case cardUnavailable
    /// The run ended in a processing failure before it reached Capturing.
    case runFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .microphoneNotAllowed: "Open VCDR once to allow microphone access."
        case .liveActivitiesOff: "Turn on Live Activities for VCDR in Settings."
        case .cardUnavailable: "VCDR couldn't show its recording card. Try again."
        case .runFailed(let message): "\(message)"
        }
    }
}
#endif
