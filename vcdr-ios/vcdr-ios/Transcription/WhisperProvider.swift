import Foundation
import OSLog
import WhisperKit

actor WhisperProvider: StreamingTranscriptionProvider {

    /// Which Whisper this provider runs. One provider per checkpoint, each
    /// downloading, sizing and loading its own weights, so a person whose phone
    /// cannot keep up with the largest can install a smaller one instead.
    private let checkpoint: WhisperCheckpoint

    nonisolated var model: TranscriptionModel { checkpoint.model }

    init(checkpoint: WhisperCheckpoint) {
        self.checkpoint = checkpoint
    }

    /// The Hugging Face repository the variant is published in. Named once
    /// because two things derive from it: where the download goes, and where the
    /// next launch looks for what a previous one downloaded.
    private static let repo = "argmaxinc/whisperkit-coreml"

    /// Where a download puts this variant's files under the owned model root —
    /// the app group's own storage, which is what survives a relaunch and what
    /// the Library sizes and deletes. Asked of WhisperKit's own Hub client
    /// rather than spelled out, because the layout under the root is the SDK's
    /// to choose and only it can be trusted to say what it chose.
    nonisolated var installedDirectory: URL {
        HubApiWrapper(downloadBase: TranscriptionModelRoot.url)
            .localRepoLocation(HubApiWrapper.Repo(id: Self.repo))
            .appending(path: checkpoint.rawValue)
    }

    /// The CoreML components WhisperKit's own `loadModels` looks for by these
    /// exact names before it will run a job.
    private static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// WhisperKit publishes no local-inventory API — its own reference app reads
    /// the variant's folder. Checking that the folder exists is not enough: an
    /// install interrupted after its first file also leaves a folder, and the
    /// three components it moves files into place one at a time are what a load
    /// actually needs present.
    nonisolated var isInstalled: Bool {
        TranscriptionModelFiles(directory: installedDirectory).hasAllComponents(named: Self.requiredComponents)
    }

    private var whisper: WhisperKit?
    private(set) var isReady = false
    private(set) var initPhase: ModelPreparationPhase = .preparing

    /// The attempt currently running. Recording never waits for a model to be
    /// ready before it starts (`docs/adr/0006`), so a launch warm and a run's
    /// own preparation genuinely race: actors interleave at await points, and
    /// without a shared attempt the two would download the model twice. A
    /// second caller waits on the first attempt instead.
    private var attempt: Task<WhisperKit, Error>?

    /// The loaded model, having prepared it if this is the first ask. The
    /// session asks through here rather than initializing and then reading a
    /// property, so there is no window in which preparation succeeded and the
    /// model is still nil.
    func prepared() async throws -> WhisperKit {
        if let whisper { return whisper }
        if let attempt { return try await attempt.value }
        let attempt = Task { try await self.prepare() }
        self.attempt = attempt
        let result = await attempt.result
        self.attempt = nil
        return try result.get()
    }

    func initialize() async throws {
        _ = try await prepared()
    }

    private func prepare() async throws -> WhisperKit {
        initPhase = .preparing
        let totalStart = ContinuousClock.now
        Logger.transcription.info("Initializing \(self.model.displayName) CoreML model...")

        do {
            // Phase 1: Fetch the artifacts, unless the model root already holds
            // them. `WhisperKit.download` asks the Hub which folder the variant
            // lives in before it fetches anything, so a launch that already has
            // the files would both announce a download that never happens and
            // need a connection to find out it was not needed.
            let root = TranscriptionModelRoot.url
            let modelDirectory = installedDirectory
            if !isInstalled {
                initPhase = .downloadingModel
                let downloadStart = ContinuousClock.now
                _ = try await WhisperKit.download(
                    variant: checkpoint.rawValue,
                    downloadBase: root,
                    from: Self.repo
                )
                Logger.transcription.info("Model download completed in \(self.elapsedMs(since: downloadStart))")
            }

            // Phase 2: Compile CoreML models for the Neural Engine (the slow
            // part). The root travels as `downloadBase` even though the weights
            // are already resolved: the tokenizer is fetched separately from
            // them, and without it that fetch would land in WhisperKit's own
            // cache under Documents rather than in the root the Library owns.
            initPhase = .loadingModel
            let loadStart = ContinuousClock.now
            let whisper = try await WhisperKit(WhisperKitConfig(
                model: checkpoint.rawValue,
                downloadBase: root,
                modelRepo: Self.repo,
                modelFolder: modelDirectory.path,
                verbose: false,
                load: true,
                download: false
            ))
            Logger.transcription.info("Model compilation completed in \(self.elapsedMs(since: loadStart))")

            self.whisper = whisper
            self.isReady = true
            initPhase = .ready
            Logger.transcription.info("\(self.model.displayName) ready (total: \(self.elapsedMs(since: totalStart)))")
            return whisper
        } catch {
            // Classified here, where the failing step and the backend's own
            // error are both still in hand; the raw text goes to the log and
            // no further.
            let failure = PreparationFailure(error: error)
            initPhase = .failed(failure)
            Logger.transcription.error("Failed to initialize \(self.model.displayName): \(error)")
            throw TranscriptionError.initializationFailed(failure.message)
        }
    }

    nonisolated func makeLiveSession(settings: TranscriptionModelSettings) -> any RecordingStreamingSession {
        WhisperLiveSession(provider: self, settings: settings)
    }

    /// What `settings` mean to WhisperKit's decoder.
    ///
    /// A Language Hint of Detect must leave `language` nil *and* ask for
    /// detection: with neither, WhisperKit fills the prefill's language slot
    /// with its own default of English, which is exactly the silent
    /// wrong-language transcript Detect exists to avoid. A named hint is the
    /// opposite — the token is forced and detection is off, which is what the
    /// person choosing it asked for.
    ///
    /// The prompt is encoded here rather than by the caller because only a
    /// loaded model has a tokenizer. An empty prompt is left absent rather than
    /// sent as no tokens: a bare prompt marker with nothing after it biases the
    /// model toward ending the segment early.
    static func decodingOptions(
        for settings: TranscriptionModelSettings,
        tokenizedBy tokenizer: (any WhisperTokenizer)?
    ) -> DecodingOptions {
        let promptTokens = tokenizer.map { tokenizer in
            // Leading space and the special-token filter are how WhisperKit's
            // own server encodes a caller's prompt: the prompt joins the
            // decoder's text, and a special token smuggled in through it would
            // rewrite the prefill.
            tokenizer.encode(text: " " + settings.freeTextPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        } ?? []
        return DecodingOptions(
            language: settings.languageHint.languageCode,
            usePrefillPrompt: true,
            detectLanguage: settings.languageHint == .detect,
            promptTokens: settings.freeTextPrompt.isEmpty || promptTokens.isEmpty ? nil : promptTokens
        )
    }

    // MARK: - Constants
    private static let millisecondsPerSecond: Double = 1000
    private static let attosecondsPerMillisecond: Double = 1e15

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * Self.millisecondsPerSecond
            + Double(duration.components.attoseconds) / Self.attosecondsPerMillisecond
        return String(format: "%.0fms", ms)
    }
}
