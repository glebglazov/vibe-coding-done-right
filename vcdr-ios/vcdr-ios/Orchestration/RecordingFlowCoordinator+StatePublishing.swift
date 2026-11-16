import Foundation
import OSLog

/// Recording-state publishing: writes the coordinator's recording state (and
/// the optional bundled result) to the App Group so the keyboard extension can
/// read it, plus the stale-result cleanup that returns the channel to idle.
extension RecordingFlowCoordinator {

    /// Publishes a Processing Failure the coordinator itself detected, before
    /// or without a Recording Run to route it through its completion adapters.
    /// Carries the same reason the app surface shows, the way the Bundled
    /// Result carries its text (ADR-0004).
    func writeFailure(reason: String) {
        Logger.recording.error("Wire state written: failed — \(reason)")
        keyboardChannel.publishFailure(reason: reason)
    }

    /// Writes recording state to App Group so the keyboard extension can read it.
    /// When `bundledText` is provided, the value is written as `"idle|text"` so the
    /// keyboard can reliably receive the transcription via the same key that syncs state.
    ///
    /// Runs on the main actor, as every other state write does. The main actor
    /// gives the writes their order, so a later write always replaces an
    /// earlier one on the wire (ADR-0004).
    ///
    /// Logs every value it writes: this and the completion adapters are the
    /// only two writers on the wire, so logging both makes the published state
    /// sequence for a run reconstructable from the log alone (ADR-0004). The
    /// Bundled Result is logged by length — the transcript itself is already
    /// logged once, by the run.
    func writeState(_ recordingState: RecordingState, bundledText: String? = nil) {
        if let bundledText, recordingState == .idle {
            Logger.recording.info("Wire state written: bundledResult (\(bundledText.count) chars)")
            keyboardChannel.publishBundledResult(bundledText)
            return
        }
        let wireState = KeyboardChannel.RecordingState(recordingState)
        Logger.recording.info("Wire state written: \(wireState.rawValue)")
        keyboardChannel.publish(wireState)
    }

    func cleanupStaleResults() {
        keyboardChannel.clearCommand()
        writeState(.idle)
    }
}

private extension KeyboardChannel.RecordingState {
    nonisolated init(_ state: RecordingState) {
        switch state {
        case .idle: self = .idle
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .emptyResult: self = .emptyResult
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        }
    }
}
