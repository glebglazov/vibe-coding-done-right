import Foundation
import OSLog
import WhisperKit

actor WhisperProvider: TranscriptionProvider {

    /// Which Whisper this provider runs. One provider per checkpoint, each
    /// downloading, sizing and loading its own weights, so a person whose Mac
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

    /// Where a download puts this variant's files under the owned model root.
    /// Asked of WhisperKit's own Hub client rather than spelled out, because the
    /// layout under the root is the SDK's to choose and only it can be trusted
    /// to say what it chose.
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

    private(set) var downloadProgress: Double?

    /// WhisperKit filters the variants it publishes through a support config
    /// fetched from the repo, so what this Mac can run is a network answer and
    /// a Mac too old for the variant is told so rather than offered it.
    /// Absent from every device's list is a different answer again: argmax
    /// publishes `openai_whisper-medium` but ranks it for no device at all, and
    /// a config with no opinion about a checkpoint has not refused it. Such a
    /// checkpoint stands on being published.
    func isInstallableOnThisDevice() async throws -> Bool {
        let runnableHere = try await WhisperKit.fetchAvailableModels(
            from: Self.repo,
            downloadBase: TranscriptionModelRoot.url
        )
        if runnableHere.contains(checkpoint.rawValue) { return true }
        let rankedAnywhere = await WhisperKit.fetchModelSupportConfig(
            from: Self.repo,
            downloadBase: TranscriptionModelRoot.url
        ).knownModels
        return !rankedAnywhere.contains(checkpoint.rawValue)
    }

    private var whisper: WhisperKit?
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

    func initialize() async throws {
        guard !isReady else { return }
        if let attempt {
            return try await attempt.value
        }
        let attempt = Task { try await self.prepare() }
        self.attempt = attempt
        let result = await attempt.result
        self.attempt = nil
        try result.get()
    }

    private func prepare() async throws {
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
                    from: Self.repo,
                    progressCallback: { [weak self] progress in
                        Task { await self?.report(downloaded: progress.fractionCompleted) }
                    }
                )
                downloadProgress = nil
                Logger.transcription.info("Model download completed in \(self.elapsedMs(since: downloadStart))")
            }

            // Phase 2: Compile CoreML models for Neural Engine (the slow part).
            // The root travels as `downloadBase` even though the weights are
            // already resolved: the tokenizer is fetched separately from them,
            // and without it that fetch would land in WhisperKit's own cache
            // under Documents rather than in the root the Library owns.
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
        } catch {
            // Classified here, where the failing step and the backend's own
            // error are both still in hand; the raw text goes to the log and
            // no further.
            let failure = PreparationFailure(error: error)
            initPhase = .failed(failure)
            Logger.transcription.error("Failed to initialize \(self.model.displayName): \(error)")
            throw TranscriptionError.initializationFailed(failure)
        }
    }

    /// Hops the Hub client's progress onto this actor, where the Library polls
    /// it from.
    private func report(downloaded fraction: Double) {
        downloadProgress = fraction
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
    /// The prompt is encoded by the caller because only a loaded model has a
    /// tokenizer, and an empty prompt is left absent rather than sent as no
    /// tokens: a bare prompt marker with nothing after it biases the model
    /// toward ending the segment early.
    static func decodingOptions(
        for settings: TranscriptionModelSettings,
        encodePrompt: (String) -> [Int]
    ) -> DecodingOptions {
        let promptTokens = encodePrompt(settings.freeTextPrompt)
        let prompt = settings.freeTextPrompt.isEmpty || promptTokens.isEmpty ? nil : promptTokens
        return DecodingOptions(
            language: settings.languageHint.languageCode,
            usePrefillPrompt: true,
            detectLanguage: settings.languageHint == .detect,
            promptTokens: prompt
        )
    }

    func transcribe(audioFileURL: URL, settings: TranscriptionModelSettings) async throws -> String {
        guard let whisper else {
            throw TranscriptionError.providerUnavailable
        }

        Logger.transcription.info("Transcribing audio file: \(audioFileURL.lastPathComponent)")

        do {
            let options = Self.decodingOptions(for: settings) { prompt in
                guard let tokenizer = whisper.tokenizer else { return [] }
                // Leading space and the special-token filter are how
                // WhisperKit's own server encodes a caller's prompt: the
                // prompt joins the decoder's text, and a special token
                // smuggled in through it would rewrite the prefill.
                return tokenizer.encode(text: " " + prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            // A recording longer than one 30-second window comes back as
            // several results, in order; the merge is how WhisperKit itself
            // puts them back into one transcript.
            let results = try await whisper.transcribe(audioPath: audioFileURL.path, decodeOptions: options)
            let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
            let text = merged.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.transcription.info("Transcription complete (\(text.count) chars)")
            return text
        } catch {
            Logger.transcription.error("Transcription failed: \(error)")
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
}
