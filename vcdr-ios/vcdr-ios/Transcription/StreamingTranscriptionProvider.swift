import Foundation

/// A Transcription Model iOS can run. Every model here drives the live view —
/// that is the only path a recording takes on this platform, which is why the
/// protocol is worded as a live session rather than as a file to transcribe the
/// way the macOS one is.
protocol StreamingTranscriptionProvider: Sendable {
    /// Which Transcription Model this provider runs, so a caller can key
    /// settings and Library membership by it rather than by its wording.
    var model: TranscriptionModel { get }
    /// What the provider is doing while it gets ready. Every readiness surface
    /// words the wait from this, so none of them has to guess from a boolean.
    var initPhase: ModelPreparationPhase { get async }
    /// Prepares the model: the download, then the load.
    func initialize() async throws
    /// The live session that runs this model for one Recording Run, told what
    /// its family has been told. A family that declares no Capability is handed
    /// the settings like any other and reads nothing out of them.
    ///
    /// Made by the provider because the two families reach a live view by
    /// different routes — a sliding window over an offline encoder, and chunked
    /// re-decoding (`docs/adr/0022`) — and only the provider knows which of
    /// them it is. Synchronous, because capture begins before the model has
    /// finished loading (`docs/adr/0006`) and the session has to exist to
    /// receive those first buffers.
    nonisolated func makeLiveSession(settings: TranscriptionModelSettings) -> any RecordingStreamingSession
    /// Prepares the model at launch, running `beforeTheHeavyLoad` in whatever
    /// gap this backend's preparation leaves for it. The audio engine's HAL
    /// warm goes in that gap: it must finish before the load that competes with
    /// it for the neural engine (`docs/adr/0002`).
    func prepareAtLaunch(
        priority: TaskPriority,
        predictedVerdict: LaunchVerdict,
        beforeTheHeavyLoad: @Sendable () async -> Void
    ) async throws
    /// What this launch's model load cost, from a backend that measures its own
    /// loads. The Launch Verdict it carries is a claim about the system CoreML
    /// cache, and only a backend that times each model file can make one.
    var launchLoadOutcome: LaunchLoadOutcome? { get async }
}

extension StreamingTranscriptionProvider {
    /// A preparation with no gap to overlap: the warm finishes first, and the
    /// load has the neural engine to itself afterwards.
    func prepareAtLaunch(
        priority: TaskPriority,
        predictedVerdict: LaunchVerdict,
        beforeTheHeavyLoad: @Sendable () async -> Void
    ) async throws {
        await beforeTheHeavyLoad()
        try await initialize()
    }

    var launchLoadOutcome: LaunchLoadOutcome? { nil }
}
