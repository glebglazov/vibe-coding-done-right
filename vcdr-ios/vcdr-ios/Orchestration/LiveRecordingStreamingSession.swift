import AVFoundation
import FluidAudio
import Foundation

actor LiveRecordingStreamingSession: RecordingStreamingSession {
    private let streaming = StreamingAsrManager(config: .streaming)

    func start(using transcriptionProvider: any StreamingTranscriptionProvider) async throws {
        try await transcriptionProvider.initialize()
        guard let models = await transcriptionProvider.loadedModels else {
            throw TranscriptionError.providerUnavailable
        }
        try await streaming.start(models: models, source: .microphone)
    }

    func streamAudio(_ buffer: AVAudioPCMBuffer) async {
        await streaming.streamAudio(buffer)
    }

    func cancel() async {
        await streaming.cancel()
    }

    func finish() async throws -> String {
        try await streaming.finish()
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
