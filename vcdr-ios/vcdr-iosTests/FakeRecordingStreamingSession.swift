import AVFoundation
import Foundation
@testable import vcdr_ios

/// A live session that finishes with whatever it was handed, so a Recording
/// Run's own behaviour can be driven without a transcription model.
actor FakeRecordingStreamingSession: RecordingStreamingSession {
    private let result: Result<String, any Error>

    init(result: Result<String, any Error> = .success("")) {
        self.result = result
    }

    func start() async throws {}

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        try result.get()
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
