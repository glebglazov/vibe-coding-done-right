import Foundation
@testable import vcdr_ios

/// A Transcription Model provider whose preparation a test drives by hand, with
/// its own directory on disk that a test fills to make the model look installed
/// — the real download and the real load replaced, everything the Library reads
/// left where it reads it.
actor FakeInstallableProvider: StreamingTranscriptionProvider {
    let model: TranscriptionModel

    nonisolated let installedDirectory: URL
    nonisolated var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedDirectory.path)
    }

    private(set) var initPhase: ModelPreparationPhase = .preparing
    /// How many times preparation has been started on this provider — the seam
    /// a test uses to ask whether an install ran at all, and whether it ran
    /// twice.
    private(set) var preparationsBegun = 0
    private(set) var downloadProgress: Double?

    private var isInstallable = true
    private var installabilityError: (any Error)?

    init(model: TranscriptionModel, installedDirectory: URL) {
        self.model = model
        self.installedDirectory = installedDirectory
    }

    /// Enters the download phase the way the real provider does, reporting the
    /// progress its backend would — a fraction, or nothing at all.
    func beginDownload(progress: Double? = nil) {
        downloadProgress = progress
        initPhase = .downloadingModel
    }

    /// Enters the load phase the way the real provider does once the files are
    /// on disk — the seam a test uses to watch a cold CoreML load from outside.
    func beginLoading() {
        initPhase = .loadingModel
    }

    func becomeReady() {
        downloadProgress = nil
        initPhase = .ready
    }

    /// Preparation gives up the way the real provider does — the failure rides
    /// on the phase, so every caller waiting on the model learns of it there.
    func fail(_ failure: PreparationFailure) {
        initPhase = .failed(failure)
    }

    /// The answer the backend's support table would give, or the failure asking
    /// for it would raise.
    func setInstallability(supported: Bool = true, error: (any Error)? = nil) {
        isInstallable = supported
        installabilityError = error
    }

    func isInstallableOnThisDevice() async throws -> Bool {
        if let installabilityError { throw installabilityError }
        return isInstallable
    }

    /// Holds preparation open until the test says how it ended, the way a real
    /// download and load hold it open — that wait is what a Library row is for.
    func initialize() async throws {
        preparationsBegun += 1
        while !Task.isCancelled {
            switch initPhase {
            case .ready: return
            case .failed(let failure): throw TranscriptionError.initializationFailed(failure.message)
            default: try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    nonisolated func makeLiveSession(settings: TranscriptionModelSettings) -> any RecordingStreamingSession {
        FakeRecordingStreamingSession()
    }
}
