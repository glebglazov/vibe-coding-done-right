import Foundation
import OSLog

/// Arming Deadline (ADR-0005): a Recording Run that produces no first audio
/// buffer within five seconds of beginning capture terminates as a Processing
/// Failure. Keyed on the first buffer — not on the audio engine reporting that
/// it started — so a hung `startCapture` still fails honestly.
extension RecordingRun {
    /// Upper bound on Arming without a first audio buffer. Sits above the
    /// worst healthy cold path observed (~2.4s tap-to-buffer).
    static let armingDeadline: Duration = .seconds(5)
    static let armingDeadlineFailureMessage =
        "Microphone didn't start in time — no audio was captured"

    /// Starts the Arming Deadline as soon as the run begins listening for
    /// capture. Success is the first audio buffer — not engine-start return.
    func startArmingDeadline() {
        armingDeadlineTask?.cancel()
        armingDeadlineTask = Task { [weak self] in
            guard let self else { return }
            await self.clock.sleep(for: Self.armingDeadline)
            guard !Task.isCancelled else { return }
            await self.armingDeadlineElapsed()
        }
    }

    func cancelArmingDeadline() {
        armingDeadlineTask?.cancel()
        armingDeadlineTask = nil
    }

    func noteFirstAudioBuffer() {
        guard !hasReceivedFirstAudioBuffer else { return }
        hasReceivedFirstAudioBuffer = true
        cancelArmingDeadline()
    }

    func armingDeadlineElapsed() async {
        guard !isTerminal, !hasReceivedFirstAudioBuffer else { return }
        Logger.recording.error(
            "Arming Deadline elapsed with no first audio buffer — terminating as Processing Failure"
        )
        cancelSetup()
        await streaming.cancel()
        _ = await finish(.processingFailure(
            RecordingRunFailure(message: Self.armingDeadlineFailureMessage)
        ))
        // Revoke the capture after claiming the terminal state, so a hung
        // `startCapture` returns no lease and leaves the microphone closed.
        audioRecorder.stopCapture(for: id)
    }
}
