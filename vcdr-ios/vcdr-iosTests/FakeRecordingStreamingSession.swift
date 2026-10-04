import AVFoundation
import Foundation
@testable import vcdr_ios

/// A live session that finishes with whatever it was handed, so a Recording
/// Run's own behaviour can be driven without a transcription model.
actor FakeRecordingStreamingSession: RecordingStreamingSession {
    private let result: Result<String, any Error>
    private let finishDelay: Duration

    init(result: Result<String, any Error> = .success(""), finishDelay: Duration = .zero) {
        self.result = result
        self.finishDelay = finishDelay
    }

    func start() async throws {}

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        try await Task.sleep(for: finishDelay)
        return try result.get()
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
