import Foundation
import FluidAudio
import OSLog

actor ParakeetProvider: TranscriptionProvider {
    let model = TranscriptionModel.parakeetUltra

    /// The FluidAudio build `model` names.
    private static let version: AsrModelVersion = .ultra

    /// The queue every provider shares, so this model's preparation waits for
    /// another model's rather than competing with it for the neural engine.
    private let preparationQueue: ModelPreparationQueue

    /// The model root this provider installs into, and deletes what Ultra
    /// replaced from.
    private let modelRoot: URL

    init(preparationQueue: ModelPreparationQueue, modelRoot: URL = TranscriptionModelRoot.url) {
        self.preparationQueue = preparationQueue
        self.modelRoot = modelRoot
    }

    /// Where FluidAudio's files live under the owned model root. The SDK's own
    /// folder name is kept, because `AsrModels` recomputes the repo path from
    /// the parent directory and would not find files under any other name.
    nonisolated var installedDirectory: URL {
        TranscriptionModelRoot.directory(
            named: AsrModels.defaultCacheDirectory(for: Self.version).lastPathComponent,
            in: modelRoot
        )
    }

    nonisolated var isInstalled: Bool {
        AsrModels.modelsExist(at: installedDirectory, version: Self.version)
    }

    /// FluidAudio can report download progress, but this provider does not
    /// pass it a handler yet, so the Library shows the time spent instead.
    nonisolated var downloadProgress: Double? { nil }

    /// FluidAudio publishes one build for every Apple Silicon Mac and no
    /// support table to consult, so this needs neither the network nor a maybe.
    func isInstallableOnThisDevice() async throws -> Bool { true }

    private var asr: AsrManager?
    private(set) var isReady = false

    private(set) var initPhase: ModelPreparationPhase = .preparing

    /// The attempt currently running. A Preparation Failure offers a retry, so
    /// re-entry is a real path: actors interleave at await points, and without
    /// a shared attempt a retry pressed during a slow one would download the
    /// model twice. A second caller waits on the first attempt instead.
    private var attempt: Task<Void, Error>?

    // MARK: - Constants
    private static let millisecondsPerSecond: Double = 1000
    private static let attosecondsPerMillisecond: Double = 1e15

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * Self.millisecondsPerSecond
            + Double(duration.components.attoseconds) / Self.attosecondsPerMillisecond
        return String(format: "%.0fms", ms)
    }

    func initialize(urgency: PreparationUrgency) async throws {
        guard !isReady else { return }
        if let attempt {
            return try await attempt.value
        }
        let attempt = Task { try await self.prepareInTurn(urgency: urgency) }
        self.attempt = attempt
        let result = await attempt.result
        self.attempt = nil
        try result.get()
    }

    /// The download and the load, run once no other model is in them.
    private func prepareInTurn(urgency: PreparationUrgency) async throws {
        try await preparationQueue.takingTurn(
            urgency: urgency,
            whileHeldBack: { await self.reportHeldBack() }
        ) {
            try await self.prepare()
        }
    }

    /// Says the model is queued rather than moving, so every readiness surface
    /// shows a wait that is real instead of one that looks like a hang.
    private func reportHeldBack() {
        initPhase = .waitingItsTurn
    }

    private func prepare() async throws {
        initPhase = .preparing
        let totalStart = ContinuousClock.now
        Logger.transcription.info("Initializing Parakeet Ultra CoreML model...")

        do {
            // Phase 1: Fetch the artifacts, unless the model root already
            // holds them — `download` short-circuits on a filled root, so
            // entering the downloading phase there would announce a download
            // that never happens.
            let downloadStart = ContinuousClock.now
            let modelDir = installedDirectory
            if !isInstalled {
                initPhase = .downloadingModel
            }
            _ = try await AsrModels.download(to: modelDir, version: Self.version)
            Logger.transcription.info("Model download/cache check completed in \(self.elapsedMs(since: downloadStart))")

            // Phase 2: Compile CoreML models for Neural Engine (the slow part)
            initPhase = .loadingModel
            let compileStart = ContinuousClock.now
            let models = try await AsrModels.load(from: modelDir, version: Self.version)
            Logger.transcription.info("Model compilation completed in \(self.elapsedMs(since: compileStart))")

            let initStart = ContinuousClock.now
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Logger.transcription.info("ASR manager initialized in \(self.elapsedMs(since: initStart))")

            self.asr = manager
            self.isReady = true
            initPhase = .ready
            Logger.transcription.info("Parakeet Ultra ready (total: \(self.elapsedMs(since: totalStart)))")
            TranscriptionModelRoot.removeDownloads(replacedBy: model, in: modelRoot)
        } catch {
            // Classified here, where the failing step and the backend's own
            // error are both still in hand; the raw text goes to the log and
            // no further.
            let failure = PreparationFailure(error: error)
            initPhase = .failed(failure)
            Logger.transcription.error("Failed to initialize Parakeet: \(error)")
            throw TranscriptionError.initializationFailed(failure)
        }
    }

    /// `settings` and `spellingHints` are unread: Parakeet declares no
    /// Capability, so there is nothing in them this backend could be told
    /// (`docs/adr/0019`).
    func transcribe(
        audioFileURL: URL,
        settings: TranscriptionModelSettings,
        spellingHints: SpellingHints
    ) async throws -> String {
        guard let asr else {
            throw TranscriptionError.providerUnavailable
        }

        Logger.transcription.info("Transcribing audio file: \(audioFileURL.lastPathComponent)")

        return try await loggingTranscriptionTiming(audioFileURL: audioFileURL) {
            do {
                // A fresh state per recording, so no decoder context from one
                // transcript carries into the next.
                var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                let result = try await asr.transcribe(audioFileURL, decoderState: &decoderState)
                return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw TranscriptionError.transcriptionFailed(error.localizedDescription)
            }
        }
    }
}
