import AVFoundation
import Foundation

@MainActor
protocol RecordingAudioCapturing: AnyObject {
    /// Nil when the engine did not come up, or when `stopCapture(for: run)`
    /// revoked the claim while it was starting; the capture never opened.
    func startCapture(
        for run: RunID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async -> CaptureLease?
    /// Ends `run`'s capture, or revokes its claim while it is still starting.
    /// No-op for a run that holds neither.
    func stopCapture(for run: RunID)
}

extension AudioRecorder: RecordingAudioCapturing {}

nonisolated protocol RecordingStreamingSession: Sendable {
    /// Prepares the model this session runs and begins consuming the buffers
    /// captured so far. The session already knows its provider — it was made by
    /// one (`docs/adr/0022`).
    func start() async throws
    /// Synchronous + ordered: callers feed buffers FIFO from the audio thread.
    /// Implementations must not block.
    func streamAudio(_ buffer: AVAudioPCMBuffer)
    func cancel() async
    func finish() async throws -> String
    func liveTranscriptUpdates() async -> AsyncStream<String>
}
