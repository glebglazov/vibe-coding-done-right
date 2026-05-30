import Foundation
import OSLog

/// Deep-link entry points: the URL-scheme record/stop handlers the keyboard
/// extension drives when the Darwin command channel is unavailable or stale.
extension RecordingFlowCoordinator {

    /// Sets state to `.recording` synchronously so the view shows "LISTENING"
    /// on the very first frame after a deep link opens the app.
    /// Called from `onOpenURL` before the async recording flow begins.
    func prepareForDeepLinkRecording() {
        guard state != .recording && state != .transcribing else { return }
        state = .recording
        launchedViaDeepLink = true
        stoppedViaDeepLink = false
    }

    /// Called when a deep link arrives. Starts recording immediately (user stays in VCDR app).
    /// Audio capture begins right away; model initialization is awaited in the background.
    func handleRecordDeepLink() async {
        switch state {
        case .recording where audioRecorder.isRecording:
            // Already recording, ignore duplicate deep link
            break
        case .transcribing:
            break
        default:
            await startRecording(fromDeepLink: true)
        }
    }

    /// Called when the keyboard's stop fallback opens `vcdr-ios://stop`. Drives
    /// the same `stopAndTranscribe(sendToKeyboard:)` path the Darwin command
    /// would have, plus flags the run as deep-linked so the Done page shows
    /// the swipe-to-paste hint. The `sendToKeyboard: true` write is what flips
    /// the keyboard's stuck "transcribing" pill to either bundled text (auto-
    /// pasted on next viewWillAppear) or an empty-result flash.
    func handleStopDeepLink() async {
        guard audioRecorder.isRecording else {
            // Cold-launch / orphaned path: nothing was recording, audio
            // buffers are gone. Surface emptyResult so the keyboard's 15s
            // polling doesn't time out staring at "transcribing". Skip when
            // a stop is already mid-flight or just finished — that pipeline
            // will publish its own result.
            switch state {
            case .transcribing, .complete:
                break
            default:
                writeState(.emptyResult)
            }
            return
        }
        launchedViaDeepLink = true
        stoppedViaDeepLink = true
        await stopAndTranscribe(sendToKeyboard: true)
    }
}
