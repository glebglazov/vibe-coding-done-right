import AVFoundation
import FluidAudio
import Foundation
import os

actor LiveRecordingStreamingSession: RecordingStreamingSession {
    private let streaming = StreamingAsrManager(config: .streaming)

    // Ordered, lossless audio pipeline. The capture callback yields buffers
    // synchronously (`streamAudio`, nonisolated + thread-safe + FIFO); a single
    // drain task feeds them into the manager IN ORDER. This replaces the old
    // per-buffer `Task { await streaming.streamAudio(buffer) }` spawn, which
    // (a) let buffers reach the manager out of order, and (b) flooded the
    // cooperative thread pool during cold model load — starving the main actor
    // and dropping the trailing buffers `finish()` overtook.
    private let bufferStream: AsyncStream<AVAudioPCMBuffer>
    private let bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var drainTask: Task<Void, Never>?

    /// Written by the audio render thread (yields), by the drain task (drains),
    /// and by `start()` (transcriber readiness); read when the session
    /// finalizes. A lock rather than actor state because `streamAudio` is
    /// nonisolated by contract — it must not suspend on the audio thread — and
    /// because the drain loop must stay off the actor to keep `finish()` from
    /// waiting behind it.
    private let tally = OSAllocatedUnfairLock(initialState: StreamingTally())

    init() {
        (bufferStream, bufferContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    func start(using transcriptionProvider: any StreamingTranscriptionProvider) async throws {
        try await transcriptionProvider.initialize()
        guard let models = await transcriptionProvider.loadedModels else {
            throw TranscriptionError.providerUnavailable
        }
        try await streaming.start(models: models, source: .microphone)
        tally.withLock { $0.recordTranscriberStarted() }
        // Start draining only after the manager is up. Buffers captured during
        // model load sit in the unbounded stream and replay here in order.
        drainTask = Task { [streaming, bufferStream, tally] in
            for await buffer in bufferStream {
                let level = AudioLevelMeter.level(of: buffer)
                let frames = Int(buffer.frameLength)
                await streaming.streamAudio(buffer)
                tally.withLock { $0.recordDrained(frames: frames, level: level) }
            }
        }
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {
        tally.withLock { $0.recordYield() }
        bufferContinuation.yield(buffer)
    }

    func cancel() async {
        bufferContinuation.finish()
        drainTask?.cancel()
        await streaming.cancel()
        logTally(outcome: "cancelled")
    }

    func finish() async throws -> String {
        // Close the pipe and wait for every captured buffer to reach the
        // manager before finalizing — guarantees no trailing audio is dropped.
        bufferContinuation.finish()
        await drainTask?.value
        logTally(outcome: "finalized")
        return try await streaming.finish()
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
    private func logTally(outcome: String) {
        let summary = tally.withLock { $0.summary }
        Logger.recording.info("Streaming \(outcome) — \(summary)")
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        let updates = await streaming.transcriptionUpdates
        return AsyncStream { continuation in
            let task = Task {
                for await _ in updates {
                    guard !Task.isCancelled else { break }
                    let confirmed = await streaming.confirmedTranscript
                    let volatile = await streaming.volatileTranscript
                    let full = confirmed.isEmpty ? volatile : "\(confirmed) \(volatile)"
                    continuation.yield(full.trimmingCharacters(in: .whitespaces))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
