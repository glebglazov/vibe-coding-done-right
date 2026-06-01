import AVFoundation
import FluidAudio
import Foundation

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
        // Start draining only after the manager is up. Buffers captured during
        // model load sit in the unbounded stream and replay here in order.
        drainTask = Task { [streaming, bufferStream] in
            for await buffer in bufferStream {
                await streaming.streamAudio(buffer)
            }
        }
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {
        bufferContinuation.yield(buffer)
    }

    func cancel() async {
        bufferContinuation.finish()
        drainTask?.cancel()
        await streaming.cancel()
    }

    func finish() async throws -> String {
        // Close the pipe and wait for every captured buffer to reach the
        // manager before finalizing — guarantees no trailing audio is dropped.
        bufferContinuation.finish()
        await drainTask?.value
        return try await streaming.finish()
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
