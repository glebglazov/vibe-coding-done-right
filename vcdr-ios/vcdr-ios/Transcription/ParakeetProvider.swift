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

            // Phase 2: Compile CoreML models for Neural Engine (the slow part).
            // .userInitiated (not .utility) because the user is actively staring
            // at the "Compiling..." spinner — .utility gets preempted under
            // thermal/CPU pressure and stretches the visible wait.
            initPhase = .compiling
            Logger.transcription.info("[LaunchProbe] ParakeetProvider phase=compiling set main=\(Thread.isMainThread)")
            let compileStart = ContinuousClock.now
            let models = try await Task.detached(priority: .userInitiated) {
                Logger.transcription.info("[LaunchProbe] ParakeetProvider compile detached body start main=\(Thread.isMainThread)")
                let result = try await AsrModels.load(from: modelDir, version: .v3)
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
}
