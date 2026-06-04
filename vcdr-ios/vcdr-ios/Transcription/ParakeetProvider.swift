@preconcurrency import CoreML
import Foundation
import FluidAudio
import OSLog

actor ParakeetProvider: TranscriptionProvider {
    let name = "Parakeet Multilingual v3"

    private var asr: AsrManager?
    private(set) var isReady = false
    /// Loaded models — shared with StreamingAsrManager to avoid duplicate CoreML compilation
    private(set) var loadedModels: AsrModels?
    /// Prevents duplicate initialization from actor reentrancy.
    /// Swift actors interleave at await points, so two callers can both pass
    /// `guard !isReady` before either sets it to true. This continuation-based
    /// lock makes the second caller wait for the first to finish.
    private var initInProgress: [CheckedContinuation<Void, Error>] = []
    private var isInitializing = false

    enum InitPhase: Sendable {
        case notStarted
        case downloading
        case compiling
        case ready
    }

    private(set) var initPhase: InitPhase = .notStarted

    // MARK: - Constants
    private static let millisecondsPerSecond: Double = 1000
    private static let attosecondsPerMillisecond: Double = 1e15

    /// ANE model-load time above which a launch is classified as a cold
    /// re-specialization rather than a warm cache hit. Warm `MLModel(contentsOf:)`
    /// loads land sub-second to ~2s; a purged system CoreML/E5RT cache forces
    /// re-specialization that this file's own comments clock at ~15s for the
    /// encoder. 3s sits well clear of the warm band.
    private static let coldSpecializationThresholdMs: Double = 3000

    /// Per-model `MLModel(contentsOf:)` load durations, used to classify a
    /// launch as warm vs. cold ANE specialization.
    private struct ModelLoadTimings: Sendable {
        let preprocessorMs: Double
        let encoderMs: Double
        let decoderMs: Double
        let jointMs: Double
        /// The dominant cost is the three ANE-bound loads; the preprocessor is
        /// CPU-only and cheap, so the verdict keys off the slowest ANE load.
        var maxAneMs: Double { max(encoderMs, max(decoderMs, jointMs)) }
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * Self.millisecondsPerSecond
            + Double(duration.components.attoseconds) / Self.attosecondsPerMillisecond
        return String(format: "%.0fms", ms)
    }

    func initialize() async throws {
        try await initialize(priority: .userInitiated)
    }

    func initialize(priority: TaskPriority) async throws {
        Logger.transcription.info("[LaunchProbe] ParakeetProvider.initialize entry main=\(Thread.isMainThread)")
        guard !isReady else { return }

        // If another call is already initializing, wait for it instead of
        // starting a duplicate compilation (actor reentrancy at await points).
        if isInitializing {
            Logger.transcription.info("Initialization already in progress, waiting...")
            try await withCheckedThrowingContinuation { continuation in
                initInProgress.append(continuation)
            }
            return
        }

        isInitializing = true
        let totalStart = ContinuousClock.now
        Logger.transcription.info("Initializing Parakeet v3 CoreML model...")

        // Snapshot whether the compiled .mlmodelc artifacts already exist on
        // disk BEFORE touching the network. Application Support is not purged by
        // iOS under storage pressure, so onDisk=false means a genuine first run
        // or reinstall (download is the cost), while onDisk=true means any
        // slowness below is CoreML re-specialization, not download.
        let modelsOnDisk = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
        Logger.transcription.info("[InitTiming] artifacts onDisk=\(modelsOnDisk) before download")

        do {
            // Phase 1: Fetch model BYTES only if not cached. We deliberately call
            // `DownloadUtils.downloadRepo` (pure URLSession, "does not load models")
            // instead of `AsrModels.download`. The latter's convenience path runs a
            // blocking `MLModel(contentsOf:)` ANE compile per model right after the
            // fetch (`DownloadUtils.loadModels`) — on the cooperative pool, since this
            // `await` is on the actor's executor. On a reinstall that starves the pool
            // for ~15s×4 cold compiles AND duplicates the compile that the offloaded
            // `.compiling` phase below already does correctly. Bytes only here; the
            // single compile happens off-pool in `loadModelsInParallel`.
            // Trade-off: we depend on FluidAudio's on-disk cache layout (downloadRepo
            // writes into `parent/<repo.folderName>`, which equals defaultCacheDirectory).
            initPhase = .downloading
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=downloading set main=\(Thread.isMainThread)")
            let downloadStart = ContinuousClock.now
            let modelDir = AsrModels.defaultCacheDirectory(for: .v3)
            Logger.transcription.info("[LaunchProbe] ParakeetProvider before downloadRepo main=\(Thread.isMainThread)")
            if !AsrModels.modelsExist(at: modelDir) {
                try await DownloadUtils.downloadRepo(.parakeet, to: modelDir.deletingLastPathComponent())
            }
            Logger.transcription.info("[LaunchProbe] ParakeetProvider after downloadRepo main=\(Thread.isMainThread)")
            let downloadMs = self.elapsedMs(since: downloadStart)
            Logger.transcription.info("Model download/cache check completed in \(downloadMs)")

            // Phase 2: Load CoreML models. The cost here is CoreML's per-process
            // MLModel(contentsOf:) preparation (ANE/E5RT specialization), not
            // actual compilation — the .mlmodelc artifacts on disk are already
            // compiled. FluidAudio's AsrModels.load runs the four loads
            // serially; we fan them out in parallel via the public AsrModels
            // init. Best case the OS pipelines the work; worst case it's no
            // slower than serial. Preprocessor is .cpuOnly and never competes
            // with the three ANE-bound loads.
            //
            // Automatic launch uses utility priority to preserve App Shell
            // responsiveness. A Recording Run uses user-initiated priority.
            initPhase = .compiling
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=compiling set main=\(Thread.isMainThread)")
            let compileStart = ContinuousClock.now
            let qos = DispatchQoS.QoSClass(priority)
            let (models, loadTimings) = try await Task.detached(priority: priority) {
                Logger.transcription.info("[LaunchProbe] ParakeetProvider compile detached body start main=\(Thread.isMainThread)")
                let result = try await Self.loadModelsInParallel(from: modelDir, qos: qos)
                Logger.transcription.info("[LaunchProbe] ParakeetProvider compile detached body end main=\(Thread.isMainThread)")
                return result
            }.value
            Logger.transcription.info("Model compilation completed in \(self.elapsedMs(since: compileStart))")

            // Classify the launch so a fast vs. slow start is self-explanatory
            // in the logs without diffing across runs:
            //   COLD_DOWNLOAD   — artifacts were absent on disk (first run /
            //                     reinstall / App Support eviction); download dominated.
            //   COLD_SPECIALIZE — artifacts present but ANE load was slow: the
            //                     system CoreML/E5RT specialization cache was
            //                     purged or invalidated (reboot, OS update,
            //                     storage pressure) and had to rebuild.
            //   WARM            — artifacts present and ANE specialization cached.
            let verdict: String
            if !modelsOnDisk {
                verdict = "COLD_DOWNLOAD"
            } else if loadTimings.maxAneMs >= Self.coldSpecializationThresholdMs {
                verdict = "COLD_SPECIALIZE"
            } else {
                verdict = "WARM"
            }
            Logger.transcription.info(
                "[InitTiming] launch verdict=\(verdict) onDisk=\(modelsOnDisk) downloadMs=\(downloadMs) "
                    + "encoderMs=\(String(format: "%.0f", loadTimings.encoderMs)) "
                    + "maxAneMs=\(String(format: "%.0f", loadTimings.maxAneMs))"
            )

            let initStart = ContinuousClock.now
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            Logger.transcription.info("ASR manager initialized in \(self.elapsedMs(since: initStart))")

            self.asr = manager
            self.loadedModels = models
            self.isReady = true
            initPhase = .ready
            isInitializing = false
            Logger.transcription.info("Parakeet v3 ready (total: \(self.elapsedMs(since: totalStart)))")

            // Resume any waiters
            for continuation in initInProgress {
                continuation.resume()
            }
            initInProgress.removeAll()
        } catch {
            isInitializing = false
            // Resume waiters with the error
            for continuation in initInProgress {
                continuation.resume(throwing: error)
            }
            initInProgress.removeAll()
            Logger.transcription.error("Failed to initialize Parakeet: \(error)")
            throw TranscriptionError.initializationFailed(error.localizedDescription)
        }
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        guard let asr else {
            throw TranscriptionError.providerUnavailable
        }

        Logger.transcription.info("Transcribing audio file: \(audioFileURL.lastPathComponent)")

        do {
            let result = try await asr.transcribe(audioFileURL, source: .system)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.transcription.info("Transcription complete (\(text.count) chars)")
            return text
        } catch {
            Logger.transcription.error("Transcription failed: \(error)")
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Parallel Model Loading

    /// Replacement for FluidAudio's `AsrModels.load(from:version:)` that loads
    /// the four `.mlmodelc` artifacts and the vocabulary file concurrently
    /// rather than serially. Constructs `AsrModels` via FluidAudio's public
    /// init so the result is API-compatible with `AsrManager.initialize(models:)`.
    ///
    /// Trade-off vs. upstream: we skip the wipe-on-failure recovery wrapper
    /// in `DownloadUtils.loadModels`. A corrupted cache here surfaces as an
    /// init error rather than auto-healing; acceptable because the only known
    /// failure mode is partial download, which the user can resolve by
    /// reinstalling the app or clearing model storage.
    private static func loadModelsInParallel(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> (models: AsrModels, timings: ModelLoadTimings) {
        let aneConfig = MLModelConfiguration()
        aneConfig.allowLowPrecisionAccumulationOnGPU = true
        aneConfig.computeUnits = .cpuAndNeuralEngine

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointFile)
        let vocabularyURL = repoDirectory.appendingPathComponent(ModelNames.ASR.vocabularyFile)

        // Preprocessor ops map to CPU-only across all platforms (per FluidAudio's
        // own ASR/AsrModels.swift comment), so pinning it avoids needless ANE
        // dispatch and lets it run alongside the three ANE-bound loads.
        async let preprocessor = timedLoadModel(name: "Preprocessor", url: preprocessorURL, computeUnits: .cpuOnly, qos: qos)
        async let encoder = timedLoadModel(name: "Encoder", url: encoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos)
        async let decoder = timedLoadModel(name: "Decoder", url: decoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos)
        async let joint = timedLoadModel(name: "JointDecision", url: jointURL, computeUnits: .cpuAndNeuralEngine, qos: qos)
        async let vocabulary = loadVocabulary(from: vocabularyURL)

        // Awaiting sequentially here does not serialize the loads — each
        // `async let` already started concurrently; this only collects results.
        let preprocessorResult = try await preprocessor
        let encoderResult = try await encoder
        let decoderResult = try await decoder
        let jointResult = try await joint
        let vocab = try await vocabulary

        let models = AsrModels(
            encoder: encoderResult.model,
            preprocessor: preprocessorResult.model,
            decoder: decoderResult.model,
            joint: jointResult.model,
            configuration: aneConfig,
            vocabulary: vocab,
            version: .v3
        )
        let timings = ModelLoadTimings(
            preprocessorMs: preprocessorResult.milliseconds,
            encoderMs: encoderResult.milliseconds,
            decoderMs: decoderResult.milliseconds,
            jointMs: jointResult.milliseconds
        )
        return (models, timings)
    }

    private static func timedLoadModel(
        name: String,
        url: URL,
        computeUnits: MLComputeUnits,
        qos: DispatchQoS.QoSClass
    ) async throws -> (model: MLModel, milliseconds: Double) {
        let start = ContinuousClock.now
        // `MLModel(contentsOf:)` blocks its thread for the full ANE/E5RT
        // specialization (~15s cold for the encoder). Run it on a GCD queue so
        // it never holds a cooperative-pool thread and starve the main actor.
        // The config is rebuilt inside the Sendable closure — MLModelConfiguration
        // is a non-Sendable class, but MLComputeUnits is a value type that crosses
        // the boundary cleanly.
        let model = try await withThrowingBlockingTask(qos: qos) {
            let configuration = MLModelConfiguration()
            configuration.allowLowPrecisionAccumulationOnGPU = true
            configuration.computeUnits = computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        Logger.transcription.info("[InitTiming] loaded \(name) in \(String(format: "%.0f", ms))ms")
        return (model, ms)
    }

    private static func loadVocabulary(from url: URL) async throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        guard let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in jsonDict {
            if let tokenId = Int(key) {
                vocabulary[tokenId] = value
            }
        }
        return vocabulary
    }
}
