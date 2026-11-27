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
    /// attempt both see it Arming. A command the app already took, by its
    /// Darwin command or an earlier link, starts nothing, and neither does a
    /// link while a run is current. True when the link was taken.
    @discardableResult
    func handleRecordDeepLink(_ command: CommandID) -> Bool {
        guard keyboardWire.claim(command) else {
            Logger.app.info("Record deep link ignored — its command was already taken")
            return false
        }
        guard let run = beginRecording(origin: .keyboard) else { return true }
        Task { await armUntilCapturing(run) }
        return true
    }

    /// The run as a Host Return attempt sees it.
    var hostReturnRunProgress: HostReturnRunProgress {
        switch activeRunPhase {
        case .arming: .arming
        case .capturing: .capturing
        case .finalizing, nil: .ended
        }
    }

    /// Stops the run the keyboard showed. A command already taken, a run
    /// that already ended, or a Finalizing run is left alone: each already
    /// publishes its own outcome, and no idle may replace it.
    func handleStopDeepLink(_ command: CommandID, run target: RunID) async {
        guard keyboardWire.claim(command) else {
            Logger.app.info("Stop deep link ignored — its command was already taken")
            return
        }
        guard let active = activeRun, active.run.id == target,
              RecordingToggle.stopCommand(for: active.run.phase.live) == .stop else {
            Logger.app.info("Stop deep link ignored — its run is not current or not listening")
            return
        }
        isKeyboardRun = true
        stoppedViaDeepLink = true
        await stopKeyboardRun(target)
    }
}
