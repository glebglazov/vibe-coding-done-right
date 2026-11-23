import AVFoundation
import FluidAudio
import Foundation

/// Parakeet's live view: a sliding window over the offline encoder, which
/// FluidAudio already reports as a settled transcript and a volatile tail.
/// Nothing here has to decide what has settled — the backend says so
/// (`docs/adr/0022`).
actor ParakeetLiveSession: RecordingStreamingSession {
    private let provider: ParakeetProvider
    private let streaming = SlidingWindowAsrManager(config: .streaming)
    private let audio = CapturedAudioPipeline()

    init(provider: ParakeetProvider) {
        self.provider = provider
    }

    func start() async throws {
        try await provider.initialize()
        guard let models = await provider.loadedModels else {
            throw TranscriptionError.providerUnavailable
        }
        try await streaming.loadModels(models)
        try await streaming.startStreaming(source: .microphone)
        audio.drain { [streaming] buffer in
            await streaming.streamAudio(buffer)
        }
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {
        audio.yield(buffer)
    }

    func cancel() async {
        audio.cancel()
        await streaming.cancel()
        audio.logTally(outcome: "cancelled")
    }

    func finish() async throws -> String {
        await audio.finishDraining()
        audio.logTally(outcome: "finalized")
        return try await streaming.finish()
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        let updates = await streaming.transcriptionUpdates
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates {
                    guard !Task.isCancelled else { break }
                    let live = LiveTranscript(
                        settled: update.confirmedTranscript,
                        volatile: update.volatileTranscript
                    )
                    continuation.yield(live.text)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
