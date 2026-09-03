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

    private(set) var initPhase: ModelPreparationPhase

    var isReady: Bool { mockIsReady }

    init(
        isReady: Bool = true,
        preparationPhase: ModelPreparationPhase? = nil,
        result: String = "Hello world",
        error: Error? = nil
    ) {
        self.mockIsReady = isReady
        self.initPhase = preparationPhase ?? (isReady ? .ready : .loadingModel)
        self.mockTranscribeResult = result
        self.mockTranscribeError = error
    }

    /// Finishes preparation the way `initialize()` does for the real provider —
    /// the seam a test uses to let a waiting run through.
    func becomeReady() {
        mockIsReady = true
        initPhase = .ready
    }

    /// Preparation gives up the way the real provider does — the failure rides
    /// on the phase, so every caller waiting on the model learns of it there.
    func fail(_ failure: PreparationFailure) {
        mockIsReady = false
        initPhase = .failed(failure)
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
