import AVFoundation
import Foundation
import os
import OSLog

/// The handoff from the audio tap to the run that holds the capture lease.
///
/// The tap runs on the audio render thread and the recorder on the main
/// actor, so the claim, the open capture and its tally sit behind one lock.
/// A run claims the capture before the engine warms; the claim can be revoked
/// while the engine is still starting, and then `open` refuses it. A buffer
/// that arrives after `close` reaches no handler.
nonisolated final class CaptureSink: Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    private struct Capture {
        let lease: CaptureLease
        let handler: Handler
        var tally = CaptureTally()
    }

    private struct State {
        var claimant: RunID?
        var capture: Capture?
        var hasLoggedFirstBuffer = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `run` wants the capture once the engine is up. A newer claim replaces
    /// an older one.
    func claim(for run: RunID) {
        state.withLock { $0.claimant = run }
    }

    /// Opens the capture for `run` when its claim still stands. Nil when the
    /// claim was revoked while the engine was starting.
    func open(for run: RunID, handler: @escaping Handler) -> CaptureLease? {
        state.withLock { state in
            guard state.claimant == run else { return nil }
            state.claimant = nil
            let lease = CaptureLease(run: run)
            state.capture = Capture(lease: lease, handler: handler)
            return lease
        }
    }

    /// Revokes `run`'s claim, or closes its open capture and returns what the
    /// capture handed on. Nil, and no change, for a run that holds neither.
    func close(for run: RunID) -> CaptureTally? {
        state.withLock { state in
            if state.claimant == run { state.claimant = nil }
            guard let capture = state.capture, capture.lease.run == run else { return nil }
            state.capture = nil
            return capture.tally
        }
    }

    /// The engine is gone: drops any claim and capture, and returns the lease
    /// of the capture that was cut.
    func closeAll() -> CaptureLease? {
        state.withLock { state in
            state.claimant = nil
            let cut = state.capture?.lease
            state.capture = nil
            return cut
        }
    }

    /// Called by the tap on the audio render thread for every buffer.
    func deliver(_ buffer: AVAudioPCMBuffer, level: Float) {
        let frames = Int(buffer.frameLength)
        let (handler, isFirst) = state.withLock { state -> (Handler?, Bool) in
            let isFirst = !state.hasLoggedFirstBuffer
            state.hasLoggedFirstBuffer = true
            state.capture?.tally.record(frames: frames, level: level)
            return (state.capture?.handler, isFirst)
        }
        if isFirst {
            Logger.app.info("[LaunchProbe] first audio buffer from tap handler=\(handler != nil)")
        }
        handler?(buffer)
    }
}
