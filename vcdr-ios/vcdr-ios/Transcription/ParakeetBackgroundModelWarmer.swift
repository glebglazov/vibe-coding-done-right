import FluidAudio
import Foundation
import OSLog

protocol ModelCacheWarmer: Sendable {
    func warmParakeetCache() async throws -> LaunchLoadOutcome?
}

struct ParakeetBackgroundModelWarmer: ModelCacheWarmer {
    func warmParakeetCache() async throws -> LaunchLoadOutcome? {
        let modelDirectory = ParakeetModelDirectory.url()
        guard AsrModels.modelsExist(at: modelDirectory) || ParakeetProviderTestSupport.bypassRealMLLoad else {
            Logger.transcription.info("Background model warm skipped; Parakeet artifacts are not on disk")
            return nil
        }

        let timings = try await ParakeetModelLoader.preSpecializeAllModels(
            from: modelDirectory,
            qos: .utility
        )
        return LaunchLoadOutcome(
            verdict: .warm,
            timings: timings,
            downloadMs: 0
        )
    }
}
