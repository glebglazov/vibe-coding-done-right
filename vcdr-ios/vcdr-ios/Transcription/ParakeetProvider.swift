import Foundation
import FluidAudio
import OSLog

actor ParakeetProvider: TranscriptionProvider {
    let name = "Parakeet Multilingual v3"

    private var asr: AsrManager?
    private(set) var isReady = false
    /// Loaded models — shared with StreamingAsrManager to avoid duplicate CoreML compilation
    private(set) var loadedModels: AsrModels?

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
        guard !isReady else { return }
        let totalStart = ContinuousClock.now
        Logger.transcription.info("Initializing Parakeet v3 CoreML model...")

        do {
            // Download + compile CoreML models in one step (cached after first run)
            initPhase = .downloading
            let loadStart = ContinuousClock.now
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            initPhase = .compiling
            Logger.transcription.info("Models downloaded and compiled in \(self.elapsedMs(since: loadStart))")

            let initStart = ContinuousClock.now
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Logger.transcription.info("ASR manager initialized in \(self.elapsedMs(since: initStart))")

            self.asr = manager
            self.loadedModels = models
            self.isReady = true
            initPhase = .ready
            Logger.transcription.info("Parakeet v3 ready (total: \(self.elapsedMs(since: totalStart)))")
        } catch {
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
