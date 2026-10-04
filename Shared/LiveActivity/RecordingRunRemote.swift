#if os(iOS)
import AppIntents

/// How an App Intent reaches the app's Recording Run. It lives beside the card
/// because the widget compiles `StopFromCardIntent` to build its button. Only
/// the app registers a conformer, and only the app process runs `perform()`.
@MainActor
protocol RecordingRunRemote: AnyObject, Sendable {
    /// Returns once the run reaches Capturing with its card, or ends. Returns
    /// at once while a run is already in progress.
    func startFromShortcut() async throws(RecordingRemoteRefusal)
    /// Returns the run's final text once it has finalized. Every run that ends
    /// with no text throws, so a Shortcut stops before it copies anything.
    func stopFromShortcut() async throws(RecordingRemoteRefusal) -> String
    /// Never starts a run.
    func stopFromCard() async
    /// True while a Shortcut's Stop Recording would end a run: Arming or
    /// Capturing.
    var isRecording: Bool { get }
}

nonisolated enum RecordingRemoteRefusal: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The permission prompt cannot appear while VCDR is in the background.
    case microphoneNotAllowed
    /// The system stops a background recording that has no Live Activity.
    case liveActivitiesOff
    /// ActivityKit refused the card, so the run was discarded before the
    /// system could stop it halfway.
    case cardUnavailable
    /// The run ended in a processing failure.
    case runFailed(String)
    case notRecording
    case noSpeech
    case runCancelled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .microphoneNotAllowed: "Open VCDR once to allow microphone access."
        case .liveActivitiesOff: "Turn on Live Activities for VCDR in Settings."
        case .cardUnavailable: "VCDR couldn't show its recording card. Try again."
        case .runFailed(let message): "\(message)"
        case .notRecording: "VCDR is not recording."
        case .noSpeech: "VCDR heard no speech."
        case .runCancelled: "The recording was cancelled."
        }
    }
}
#endif
