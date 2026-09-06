import AVFoundation
import Foundation
import os

/// The ordered, lossless path from the audio tap to whatever consumes a
/// recording's buffers, and the tally of what actually got through.
///
/// The capture callback yields buffers synchronously and must never suspend; a
/// single drain task feeds them onward IN ORDER. Anything else lets buffers
/// reach the consumer out of order and floods the cooperative pool during a
/// cold model load — starving the main actor and dropping the trailing buffers
/// a finish overtakes.
///
/// Both live sessions own one: a sliding window and a chunked re-decoder differ
/// in what they do with a buffer, not in how one reaches them.
final class CapturedAudioPipeline: Sendable {
    private let buffers: AsyncStream<AVAudioPCMBuffer>
    private let inlet: AsyncStream<AVAudioPCMBuffer>.Continuation

    /// Written by the audio render thread (yields), by the drain task (drains),
    /// and by the session (consumer readiness); read when the session
    /// finalizes. A lock rather than actor state because `yield` is nonisolated
    /// by contract — it must not suspend on the audio thread — and because the
    /// drain loop must stay off the session's actor to keep its finish from
    /// waiting behind it.
    private let tally = OSAllocatedUnfairLock(initialState: StreamingTally())

    private let drainTask = OSAllocatedUnfairLock(initialState: Task<Void, Never>?.none)

    init() {
        (buffers, inlet) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Hands one captured buffer to the pipeline. Called from the audio render
    /// thread, so it does no work beyond the handover.
    func yield(_ buffer: AVAudioPCMBuffer) {
        tally.withLock { $0.recordYield() }
        inlet.yield(buffer)
    }

    /// Starts feeding `consume` the buffers captured so far and everything that
    /// follows, in order. Called once the consumer is up: buffers captured
    /// while the model loaded sit in the unbounded stream and replay here.
    func drain(into consume: @escaping @concurrent @Sendable (sending AVAudioPCMBuffer) async -> Void) {
        tally.withLock { $0.recordTranscriberStarted() }
        let task = Task { [buffers, tally] in
            for await buffer in buffers {
                let level = AudioLevelMeter.level(of: buffer)
                let frames = Int(buffer.frameLength)
                await consume(buffer)
                tally.withLock { $0.recordDrained(frames: frames, level: level) }
            }
        }
        drainTask.withLock { $0 = task }
    }

    /// Closes the pipe and waits for every captured buffer to reach the
    /// consumer, so no trailing audio is dropped from the transcript.
    func finishDraining() async {
        inlet.finish()
        await drainTask.withLock { $0 }?.value
    }

    func cancel() {
        inlet.finish()
        drainTask.withLock { $0 }?.cancel()
    }

    /// The consumption half of the pipeline pair, emitted on every run so a
    /// successful run's numbers are on record as the baseline.
    ///
    /// The peak here is measured on the buffers handed to the transcriber, and
    /// the capture tap logs its own peak over the buffers it handed to us. The
    /// redundancy is the point: the tap's samples and ours are the *same
    /// buffers*, so the two peaks must agree. If they don't, the transcriber
    /// saw different samples than the tap measured — the tap's buffers are
    /// owned by AVAudioEngine and only valid for the duration of the callback,
    /// and this pipeline deliberately defers consumption past that. A drain
    /// peak near zero under a healthy tap peak is that failure, and an empty
    /// transcript with matching healthy peaks is not.
    func logTally(outcome: String) {
        let summary = tally.withLock { $0.summary }
        Logger.recording.info("Streaming \(outcome) — \(summary)")
    }
}
