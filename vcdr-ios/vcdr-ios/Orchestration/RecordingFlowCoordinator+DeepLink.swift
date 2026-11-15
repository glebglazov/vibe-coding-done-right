import Foundation
import OSLog

/// Deep-link entry points: the URL-scheme record/stop handlers the keyboard
/// extension drives when the Darwin command channel is unavailable or stale.
extension RecordingFlowCoordinator {

    /// Sets state to `.arming` synchronously so the very first frame after a
    /// deep link shows the tap was registered ("STARTING…") — not a fake
    /// "LISTENING" with no audio behind it. On a cold launch the engine may be
    /// seconds from ready; the async flow warms it and flips to `.recording`
    /// (Capturing) only once audio actually flows.
    /// Called from `onOpenURL` before the async recording flow begins.
    func prepareForDeepLinkRecording() {
        guard state != .arming && state != .recording && state != .transcribing else { return }
        state = .arming
        isKeyboardRun = true
        stoppedViaDeepLink = false
    }

    /// Called when a deep link arrives. Starts recording immediately (user stays in VCDR app).
    /// Audio capture begins right away; model initialization is awaited in the background.
    func handleRecordDeepLink() async {
        switch state {
        case .recording where isRecording:
            // Already recording, ignore duplicate deep link
            break
        case .transcribing:
            break
        default:
            await startRecording(origin: .keyboard)
        }
    }

    /// The run as a Host Return attempt sees it. Before `startRecording`
    /// creates the run, `prepareForDeepLinkRecording` has already set Arming,
    /// so no run with any other state means the run ended or never started.
    var hostReturnRunProgress: HostReturnRunProgress {
        switch activeRunPhase {
        case .arming: .arming
        case .capturing: .capturing
        case .cancellingArming, .finalizing: .ended
        case nil: state == .arming ? .arming : .ended
        }
    }

    func handleStopDeepLink() async {
        if RecordingToggle.stopCommand(for: activeRunPhase) == .stop {
            isKeyboardRun = true
            stoppedViaDeepLink = true
            await stopActiveRun()
            return
        }
        // Truly orphaned cold-launch / stale stop: nothing was recording and
        // nothing is arming, so there is no Recording Run outcome to report —
        // this is the genuine idle the keyboard now renders as plain idle.
        // Skip when a stop is already mid-flight or just finished; that pipeline
        // publishes its own terminal state.
        switch state {
        case .transcribing, .complete:
            break
        default:
            Logger.recording.info(
                "Publishing idle: stop deep link found no run to stop (state=\(String(describing: state)))"
            )
            writeState(.idle)
        }
    }
}
