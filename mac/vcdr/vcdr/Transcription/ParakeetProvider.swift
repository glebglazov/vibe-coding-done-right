import Foundation
import FluidAudio
import OSLog

actor ParakeetProvider: TranscriptionProvider {
    let name = "Parakeet Multilingual v3"

    private var asr: AsrManager?
    private(set) var isReady = false

    enum InitPhase: Sendable {
        case notStarted
        case downloading
        case compiling
        case ready
    }

    private(set) var initPhase: InitPhase = .notStarted

    func initialize() async throws {
        guard !isReady else { return }
        Logger.transcription.info("Initializing Parakeet v3 CoreML model...")

        do {
            // Phase 1: Download models if not cached (typically instant when cached)
            initPhase = .downloading
            let modelDir = try await AsrModels.download(version: .v3)
            Logger.transcription.info("Model files ready at: \(modelDir.path)")

            // Phase 2: Compile CoreML models for Neural Engine (the slow part)
            initPhase = .compiling
            let models = try await AsrModels.load(from: modelDir, version: .v3)

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asr = manager
            self.isReady = true
            initPhase = .ready
            Logger.transcription.info("Parakeet v3 initialized successfully")
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
