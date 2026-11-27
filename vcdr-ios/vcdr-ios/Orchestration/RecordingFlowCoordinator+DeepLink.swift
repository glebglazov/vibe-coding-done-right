import Foundation
import OSLog

/// Deep-link entry points: the URL-scheme record/stop handlers the keyboard
/// extension drives when the Darwin command channel is unavailable or stale.
extension RecordingFlowCoordinator {

    /// A cold launch from the record link shows Arming on its first frame,
    /// before the scene can deliver the link and begin the run. Display only:
    /// no run exists yet.
    func prepareForDeepLinkRecording() {
        guard activeRun == nil else { return }
        state = .arming
        isKeyboardRun = true
        stoppedViaDeepLink = false
    }

    /// Begins a keyboard run at once, so the first frame and the Host Return
    /// attempt both see it Arming. A run already current keeps the link from
    /// starting another.
    func handleRecordDeepLink() {
        guard let run = beginRecording(origin: .keyboard) else { return }
        Task { await armUntilCapturing(run) }
    }

    /// The run as a Host Return attempt sees it.
    var hostReturnRunProgress: HostReturnRunProgress {
        switch activeRunPhase {
        case .arming: .arming
        case .capturing: .capturing
        case .finalizing, nil: .ended
        }
    }

    func handleStopDeepLink() async {
        if RecordingToggle.stopCommand(for: activeRunPhase) == .stop {
            isKeyboardRun = true
            stoppedViaDeepLink = true
            await stopActiveRun()
            return
        }
        // A current run that is Finalizing publishes its own terminal state.
        guard activeRun == nil else { return }
        // Truly orphaned cold-launch / stale stop: nothing was recording and
        // nothing is arming, so there is no Recording Run outcome to report —
        // this is the genuine idle the keyboard now renders as plain idle.
        // A result the last run delivered stays on the wire.
        if case .complete = state { return }
        Logger.recording.info(
            "Publishing idle: stop deep link found no run to stop (state=\(String(describing: state)))"
        )
        writeState(.idle)
    }
}
