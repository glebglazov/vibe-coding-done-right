import Foundation
@testable import vcdr_mac

/// A configurable mock TranscriptionProvider for e2e tests.
/// Uses actor isolation to satisfy the Sendable requirement.
actor MockTranscriptionProvider: TranscriptionProvider {
    let name = "Mock"

    var mockIsReady: Bool
    var mockTranscribeResult: String
    var mockTranscribeError: Error?
    private(set) var transcribeCallCount = 0

    var isReady: Bool { mockIsReady }

    init(isReady: Bool = true, result: String = "Hello world", error: Error? = nil) {
        self.mockIsReady = isReady
        self.mockTranscribeResult = result
        self.mockTranscribeError = error
    }

    func initialize() async throws {
        // No-op for tests
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        transcribeCallCount += 1
        if let error = mockTranscribeError {
            throw error
        }
        return mockTranscribeResult
    }
}
