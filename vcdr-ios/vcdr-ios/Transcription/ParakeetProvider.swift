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

    private(set) var initPhase: InitPhase = .notStarted {
        didSet {
            if ParakeetProviderTestSupport.recordInitPhases, oldValue != initPhase {
                ParakeetProviderTestSupport.recordedInitPhases.append(initPhase)
            }
        }
    }

    private var loadedCore: ParakeetLoadedCoreModels?
    private var modelsOnDiskAtInit = false
    private var downloadMs: Double = 0
    private var initQoS: DispatchQoS.QoSClass = .userInitiated
    private var initTaskPriority: TaskPriority = .userInitiated

    /// Launch Verdict + timings of this process's model load, set when the
    /// encoder lands. Read by the coordinator to persist launch telemetry.
    /// Stays `nil` for test-stub loads.
    private(set) var launchLoadOutcome: LaunchLoadOutcome?

    // MARK: - Constants
    private static let millisecondsPerSecond: Double = 1000
    private static let attosecondsPerMillisecond: Double = 1e15

    /// ANE model-load time above which a launch is classified as a cold
    /// re-specialization rather than a warm cache hit. Warm `MLModel(contentsOf:)`
    /// loads land sub-second to ~2s; a purged system CoreML/E5RT cache forces
    /// re-specialization that this file's own comments clock at ~15s for the
    /// encoder. 3s sits well clear of the warm band.
    private static let coldSpecializationThresholdMs: Double = 3000

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * Self.millisecondsPerSecond
            + Double(duration.components.attoseconds) / Self.attosecondsPerMillisecond
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        String(format: "%.0fms", elapsedMilliseconds(since: start))
    }

    func initialize() async throws {
        try await initialize(priority: .userInitiated)
    }

    func initialize(priority: TaskPriority) async throws {
        guard !isReady else { return }
        if isInitializing {
            try await waitForInitialization()
            return
        }
        let predictedVerdict = await LaunchTelemetry.predictedVerdict()
        try await loadCoreModels(priority: priority, predictedVerdict: predictedVerdict)
        try await finishWithEncoder()
    }

    /// Phase 1: download model bytes (if needed), then load model files
    /// according to the Predicted Launch Verdict. Predicted-cold keeps the
    /// serial preprocessor → decoder → joint core phase; predicted-Warm fans
    /// out all four model loads and stores the encoder for phase 2. Leaves
    /// `isInitializing` true until `finishWithEncoder()` completes.
    func loadCoreModels(
        priority: TaskPriority = .userInitiated,
        predictedVerdict: LaunchVerdict = .coldSpecialize
    ) async throws {
        Logger.transcription.info("[LaunchProbe] ParakeetProvider.loadCoreModels entry main=\(Thread.isMainThread)")
        guard !isReady else { return }
        if isInitializing {
            if loadedCore != nil { return }
            try await waitForInitialization()
            return
        }

        isInitializing = true
        let totalStart = ContinuousClock.now
        Logger.transcription.info("Initializing Parakeet v3 CoreML model (core phase)...")

        modelsOnDiskAtInit = ParakeetProviderTestSupport.stubModelsOnDiskAtInit
            ?? AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
        Logger.transcription.info("[InitTiming] artifacts onDisk=\(self.modelsOnDiskAtInit) before download")

        do {
            initPhase = .downloading
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=downloading set main=\(Thread.isMainThread)")
            let downloadStart = ContinuousClock.now
            let modelDir = AsrModels.defaultCacheDirectory(for: .v3)
            Logger.transcription.info("[LaunchProbe] ParakeetProvider before downloadRepo main=\(Thread.isMainThread)")
            if !ParakeetProviderTestSupport.bypassRealMLLoad,
               !AsrModels.modelsExist(at: modelDir)
            {
                try await DownloadUtils.downloadRepo(.parakeet, to: modelDir.deletingLastPathComponent())
            }
            Logger.transcription.info("[LaunchProbe] ParakeetProvider after downloadRepo main=\(Thread.isMainThread)")
            downloadMs = self.elapsedMilliseconds(since: downloadStart)
            Logger.transcription.info("Model download/cache check completed in \(String(format: "%.0fms", self.downloadMs))")

            if ParakeetProviderTestSupport.bypassRealMLLoad {
                try await Task.sleep(for: .milliseconds(30))
            }

            initPhase = .compiling
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=compiling set main=\(Thread.isMainThread)")
            let compileStart = ContinuousClock.now
            let qos = DispatchQoS.QoSClass(priority)
            initQoS = qos
            initTaskPriority = priority

            if ParakeetProviderTestSupport.simulateCoreLoadDuration > .zero {
                try await Task.sleep(for: ParakeetProviderTestSupport.simulateCoreLoadDuration)
            }

            let core = try await Task.detached(priority: priority) {
                Logger.transcription.info("[LaunchProbe] ParakeetProvider core load detached start main=\(Thread.isMainThread)")
                let result: ParakeetLoadedCoreModels
                if predictedVerdict == .warm {
                    result = try await ParakeetModelLoader.loadAllModelsParallelForPredictedWarm(
                        from: modelDir,
                        qos: qos
                    )
                } else {
                    result = try await ParakeetModelLoader.loadCoreModelsSerial(from: modelDir, qos: qos)
                }
                Logger.transcription.info("[LaunchProbe] ParakeetProvider core load detached end main=\(Thread.isMainThread)")
                return result
            }.value
            loadedCore = core
            Logger.transcription.info("Core model load completed in \(self.elapsedMs(since: compileStart))")
        } catch {
            failInitialization(error: error)
            throw TranscriptionError.initializationFailed(error.localizedDescription)
        }
    }

    /// Phase 2: load the encoder alone (the heavy ANE specialization), then
    /// construct `AsrManager` and reach Transcription Readiness.
    func finishWithEncoder() async throws {
        Logger.transcription.info("[LaunchProbe] ParakeetProvider.finishWithEncoder entry main=\(Thread.isMainThread)")
        guard !isReady else { return }
        if isInitializing, loadedCore == nil {
            try await waitForInitialization()
            return
        }
        guard let core = loadedCore else {
            throw TranscriptionError.initializationFailed("Core models must be loaded before the encoder")
        }

        if ParakeetProviderTestSupport.simulateEncoderLoadDuration > .zero {
            try await Task.sleep(for: ParakeetProviderTestSupport.simulateEncoderLoadDuration)
        }
        if let hook = ParakeetProviderTestSupport.onFinishWithEncoderEntered {
            await hook()
        }

        let totalStart = ContinuousClock.now
        do {
            if ParakeetProviderTestSupport.failFinishWithEncoder {
                throw TranscriptionError.initializationFailed("Test encoder failure")
            }

            let qos = initQoS
            let detachedPriority = initTaskPriority
            let (encoderResult, loadTimings): ((model: MLModel?, milliseconds: Double), ParakeetModelLoadTimings)
            if let encoderMs = core.encoderLoadedDuringCorePhaseMs {
                let result = (model: core.encoderLoadedDuringCorePhase, milliseconds: encoderMs)
                encoderResult = result
                loadTimings = ParakeetModelLoadTimings(
                    preprocessorMs: core.preprocessorMs,
                    encoderMs: result.milliseconds,
                    decoderMs: core.decoderMs,
                    jointMs: core.jointMs
                )
            } else {
                (encoderResult, loadTimings) = try await Task.detached(priority: detachedPriority) {
                    Logger.transcription.info("[LaunchProbe] ParakeetProvider encoder load detached start main=\(Thread.isMainThread)")
                    let encoderResult = try await ParakeetModelLoader.loadEncoder(from: core.repoDirectory, qos: qos)
                    let timings = ParakeetModelLoadTimings(
                        preprocessorMs: core.preprocessorMs,
                        encoderMs: encoderResult.milliseconds,
                        decoderMs: core.decoderMs,
                        jointMs: core.jointMs
                    )
                    Logger.transcription.info("[LaunchProbe] ParakeetProvider encoder load detached end main=\(Thread.isMainThread)")
                    return (encoderResult, timings)
                }.value
            }

            let verdict: LaunchVerdict
            if !modelsOnDiskAtInit {
                verdict = .coldDownload
            } else if loadTimings.maxAneMs >= Self.coldSpecializationThresholdMs {
                verdict = .coldSpecialize
            } else {
                verdict = .warm
            }
            Logger.transcription.info(
                "[InitTiming] launch verdict=\(verdict.rawValue) onDisk=\(self.modelsOnDiskAtInit) "
                    + "downloadMs=\(String(format: "%.0f", self.downloadMs)) "
                    + "encoderMs=\(String(format: "%.0f", loadTimings.encoderMs)) "
                    + "maxAneMs=\(String(format: "%.0f", loadTimings.maxAneMs))"
            )
            if !core.isTestStub || ParakeetProviderTestSupport.recordLaunchOutcomeForStubLoads {
                launchLoadOutcome = LaunchLoadOutcome(
                    verdict: verdict,
                    timings: loadTimings,
                    downloadMs: downloadMs
                )
            }

            let aneConfig = MLModelConfiguration()
            aneConfig.allowLowPrecisionAccumulationOnGPU = true
            aneConfig.computeUnits = .cpuAndNeuralEngine

            if core.isTestStub {
                self.isReady = true
                self.initPhase = .ready
                self.loadedCore = nil
                self.completeInitialization(totalStart: totalStart)
                return
            }

            guard let preprocessor = core.preprocessor,
                  let decoder = core.decoder,
                  let joint = core.joint
            else {
                throw TranscriptionError.initializationFailed("Core models are incomplete")
            }

            guard let encoder = encoderResult.model else {
                throw TranscriptionError.initializationFailed("Encoder model failed to load")
            }

            let models = AsrModels(
                encoder: encoder,
                preprocessor: preprocessor,
                decoder: decoder,
                joint: joint,
                configuration: aneConfig,
                vocabulary: core.vocabulary,
                version: .v3
            )

            let initStart = ContinuousClock.now
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            Logger.transcription.info("ASR manager initialized in \(self.elapsedMs(since: initStart))")

            self.asr = manager
            self.loadedModels = models
            self.isReady = true
            self.initPhase = .ready
            self.loadedCore = nil
            self.completeInitialization(totalStart: totalStart)
        } catch {
            failInitialization(error: error)
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

    // MARK: - Initialization helpers

    private func waitForInitialization() async throws {
        Logger.transcription.info("Initialization already in progress, waiting...")
        try await withCheckedThrowingContinuation { continuation in
            initInProgress.append(continuation)
        }
    }

    private func completeInitialization(totalStart: ContinuousClock.Instant) {
        isInitializing = false
        Logger.transcription.info("Parakeet v3 ready (total: \(self.elapsedMs(since: totalStart)))")
        for continuation in initInProgress {
            continuation.resume()
        }
        initInProgress.removeAll()
    }

    private func failInitialization(error: Error) {
        isInitializing = false
        loadedCore = nil
        for continuation in initInProgress {
            continuation.resume(throwing: error)
        }
        initInProgress.removeAll()
        Logger.transcription.error("Failed to initialize Parakeet: \(error)")
    }

}
