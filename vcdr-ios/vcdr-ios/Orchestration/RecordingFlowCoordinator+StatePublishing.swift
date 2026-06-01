import Foundation

/// Recording-state publishing: writes the coordinator's recording state (and
/// the optional bundled result) to the App Group so the keyboard extension can
/// read it, plus the stale-result cleanup that returns the channel to idle.
extension RecordingFlowCoordinator {

    /// Writes recording state to App Group so the keyboard extension can read it.
    /// When `bundledText` is provided, the value is written as `"idle|text"` so the
    /// keyboard can reliably receive the transcription via the same key that syncs state.
    func writeState(_ recordingState: RecordingState, bundledText: String? = nil) {
        writeStateRaw(recordingState, bundledText: bundledText)
    }

    /// Non-MainActor version so callers can dispatch disk-flush + Darwin post
    /// off the critical path. Shared UserDefaults + DarwinNotificationCenter
    /// are thread-safe. Performs no instance state reads.
    nonisolated func writeStateAsync(_ recordingState: RecordingState, bundledText: String? = nil) async {
        writeStateRaw(recordingState, bundledText: bundledText)
    }

    private nonisolated func writeStateRaw(_ recordingState: RecordingState, bundledText: String? = nil) {
        if let bundledText, recordingState == .idle {
            keyboardChannel.publishBundledResult(bundledText)
            return
        }
        keyboardChannel.publish(KeyboardChannel.RecordingState(recordingState))
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
        }
    }
}
