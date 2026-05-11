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

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * Self.millisecondsPerSecond
            + Double(duration.components.attoseconds) / Self.attosecondsPerMillisecond
        return String(format: "%.0fms", ms)
    }

    func initialize() async throws {
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

        do {
            // Phase 1: Download models if not cached (typically instant when cached)
            initPhase = .downloading
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=downloading set main=\(Thread.isMainThread)")
            let downloadStart = ContinuousClock.now
            Logger.transcription.info("[LaunchProbe] ParakeetProvider before AsrModels.download main=\(Thread.isMainThread)")
            let modelDir = try await AsrModels.download(version: .v3)
            Logger.transcription.info("[LaunchProbe] ParakeetProvider after AsrModels.download main=\(Thread.isMainThread)")
            Logger.transcription.info("Model download/cache check completed in \(self.elapsedMs(since: downloadStart))")

            // Phase 2: Load CoreML models. The cost here is CoreML's per-process
            // MLModel(contentsOf:) preparation (ANE/E5RT specialization), not
            // actual compilation — the .mlmodelc artifacts on disk are already
            // compiled. FluidAudio's AsrModels.load runs the four loads
            // serially; we fan them out in parallel via the public AsrModels
            // init. Best case the OS pipelines the work; worst case it's no
            // slower than serial. Preprocessor is .cpuOnly and never competes
            // with the three ANE-bound loads.
            //
            // .userInitiated (not .utility) because the user is actively staring
            // at the "Compiling..." spinner — .utility gets preempted under
            // thermal/CPU pressure and stretches the visible wait.
            initPhase = .compiling
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=compiling set main=\(Thread.isMainThread)")
            let compileStart = ContinuousClock.now
            let models = try await Task.detached(priority: .userInitiated) {
                Logger.transcription.info("[LaunchProbe] ParakeetProvider compile detached body start main=\(Thread.isMainThread)")
                let result = try await Self.loadModelsInParallel(from: modelDir)
                Logger.transcription.info("[LaunchProbe] ParakeetProvider compile detached body end main=\(Thread.isMainThread)")
                return result
            }.value
            Logger.transcription.info("Model compilation completed in \(self.elapsedMs(since: compileStart))")

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
    private static func loadModelsInParallel(from repoDirectory: URL) async throws -> AsrModels {
        let preprocessorConfig = MLModelConfiguration()
        preprocessorConfig.allowLowPrecisionAccumulationOnGPU = true
        // Preprocessor ops map to CPU-only across all platforms (per FluidAudio's
        // own ASR/AsrModels.swift comment), so pinning here avoids needless ANE
        // dispatch and lets this load run alongside the three ANE-bound ones.
        preprocessorConfig.computeUnits = .cpuOnly

        let aneConfig = MLModelConfiguration()
        aneConfig.allowLowPrecisionAccumulationOnGPU = true
        aneConfig.computeUnits = .cpuAndNeuralEngine

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointFile)
        let vocabularyURL = repoDirectory.appendingPathComponent(ModelNames.ASR.vocabularyFile)

        async let preprocessor = timedLoadModel(name: "Preprocessor", url: preprocessorURL, configuration: preprocessorConfig)
        async let encoder = timedLoadModel(name: "Encoder", url: encoderURL, configuration: aneConfig)
        async let decoder = timedLoadModel(name: "Decoder", url: decoderURL, configuration: aneConfig)
        async let joint = timedLoadModel(name: "JointDecision", url: jointURL, configuration: aneConfig)
        async let vocabulary = loadVocabulary(from: vocabularyURL)

        return AsrModels(
            encoder: try await encoder,
            preprocessor: try await preprocessor,
            decoder: try await decoder,
            joint: try await joint,
            configuration: aneConfig,
            vocabulary: try await vocabulary,
            version: .v3
        )
    }

    private static func timedLoadModel(
        name: String,
        url: URL,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let start = ContinuousClock.now
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        Logger.transcription.info("[InitTiming] loaded \(name) in \(String(format: "%.0f", ms))ms")
        return model
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
