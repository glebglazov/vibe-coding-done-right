import Foundation
@testable import vcdr_mac

/// A configurable mock TranscriptionProvider for e2e tests.
/// Uses actor isolation to satisfy the Sendable requirement.
actor MockTranscriptionProvider: TranscriptionProvider {
    let model: TranscriptionModel
    let name = "Mock"

    /// The directory a test can fill to make this model look installed, and
    /// find emptied after a removal.
    nonisolated let installedDirectory: URL
    nonisolated var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedDirectory.path)
    }

    var mockDownloadProgress: Double?
    var downloadProgress: Double? { mockDownloadProgress }

    var mockIsInstallable = true
    var mockInstallabilityError: Error?

    /// Holds `initialize()` open until `becomeReady()` or `fail(_:)`, the way a
    /// real download holds it open — the seam a test needs to see what a
    /// surface says mid-preparation.
    private let holdsPreparationOpen: Bool

    /// The queue this provider prepares through, as the real ones do. Its own
    /// by default, so a test that is not about sequencing sees no queue at all;
    /// tests that are hand the same one to several providers, the way the
    /// registry does in the app.
    private let preparationQueue: ModelPreparationQueue

    var mockIsReady: Bool
    var mockTranscribeResult: String
    var mockTranscribeError: Error?
    private(set) var transcribeCallCount = 0
    /// What the last transcription was told, so a test can read the settings a
    /// whole run carried down to the model that ran it.
    private(set) var receivedSettings: TranscriptionModelSettings?
    /// The Spelling Hints the last transcription was handed.
    private(set) var receivedSpellingHints: SpellingHints?

    private(set) var initPhase: ModelPreparationPhase

    /// Whether preparation has taken its turn on the queue and begun — the
    /// seam a sequencing test uses to ask for a second preparation only once
    /// the first is observably running, rather than racing two into the queue.
    private(set) var hasTakenItsTurn = false

    var isReady: Bool { mockIsReady }

    init(
        model: TranscriptionModel = .parakeetV3,
        isReady: Bool = true,
        preparationPhase: ModelPreparationPhase? = nil,
        result: String = "Hello world",
        error: Error? = nil,
        installedDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "vcdr-mock-model-\(UUID().uuidString)"),
        holdsPreparationOpen: Bool = false,
        preparationQueue: ModelPreparationQueue = ModelPreparationQueue()
    ) {
        self.preparationQueue = preparationQueue
        self.model = model
        self.installedDirectory = installedDirectory
        self.holdsPreparationOpen = holdsPreparationOpen
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

    func stopFailing() {
        mockTranscribeError = nil
    }

    /// Enters the download phase the way the real provider does, reporting the
    /// progress its backend would — a fraction, or nothing at all.
    func beginDownload(progress: Double? = nil) {
        mockDownloadProgress = progress
        initPhase = .downloadingModel
    }

    /// Enters the load phase the way the real provider does once the files are
    /// on disk — the seam a test uses to watch a cold CoreML load from outside.
    func beginLoading() {
        initPhase = .loadingModel
    }

    /// The answer the backend's support table would give, or the failure asking
    /// for it would raise.
    func setInstallability(supported: Bool = true, error: Error? = nil) {
        mockIsInstallable = supported
        mockInstallabilityError = error
    }

    func isInstallableOnThisDevice() async throws -> Bool {
        if let mockInstallabilityError { throw mockInstallabilityError }
        return mockIsInstallable
    }

    /// Preparation starts over the way it does on the real provider when a
    /// Preparation Failure is retried: the failure the last attempt left on the
    /// phase is gone.
    func prepareAgain() {
        mockIsReady = false
        initPhase = .preparing
    }

    func initialize(urgency: PreparationUrgency) async throws {
        try await preparationQueue.takingTurn(
            urgency: urgency,
            whileHeldBack: { await self.reportHeldBack() }
        ) {
            try await self.prepare()
        }
    }

    private func reportHeldBack() {
        initPhase = .waitingItsTurn
    }

    private func prepare() async throws {
        // The real providers open their preparation on `.preparing`; a mock
        // that was held back would otherwise still be reporting the queue.
        if initPhase == .waitingItsTurn { initPhase = .preparing }
        hasTakenItsTurn = true
        guard holdsPreparationOpen else { return }
        while !Task.isCancelled {
            switch initPhase {
            case .ready: return
            case .failed(let failure): throw TranscriptionError.initializationFailed(failure)
            default: try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func transcribe(
        audioFileURL: URL,
        settings: TranscriptionModelSettings,
        spellingHints: SpellingHints
    ) async throws -> String {
        transcribeCallCount += 1
        receivedSettings = settings
        receivedSpellingHints = spellingHints
        if let error = mockTranscribeError {
            throw error
        }
        return mockTranscribeResult
    }
}
