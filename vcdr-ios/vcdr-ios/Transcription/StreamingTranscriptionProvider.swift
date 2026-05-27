import FluidAudio
import Foundation

protocol StreamingTranscriptionProvider: Sendable {
    func initialize() async throws
    var loadedModels: AsrModels? { get async }
}

extension ParakeetProvider: StreamingTranscriptionProvider {}
