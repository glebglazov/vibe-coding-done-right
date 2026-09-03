import Foundation

/// What the transcription model is doing while it gets ready. One vocabulary
/// for both products, so macOS and iOS cannot word the same wait differently.
enum ModelPreparationPhase: Sendable {
    /// Initialization has not begun.
    case preparing
    /// Artifacts are being fetched. A launch that finds them already cached
    /// never enters this phase, and so must never claim to be downloading.
    case downloadingModel
    /// Artifacts are on disk, being compiled and loaded.
    case loadingModel
    case ready
}

extension ModelPreparationPhase {
    /// Seconds a phase must last before its label gains a Preparation
    /// Heartbeat. Fast preparations stay quiet; slow ones get a visible tick.
    static let heartbeatRevealThreshold: Int = 2

    /// The label every readiness surface renders for this phase. Past the
    /// reveal threshold it carries a Preparation Heartbeat — the seconds spent
    /// in the phase — because the transcription backend reports no progress of
    /// its own, so elapsed time is the only honest number available.
    func label(elapsedSeconds: Int) -> String {
        let phaseLabel: String
        switch self {
        case .preparing: phaseLabel = "Preparing"
        case .downloadingModel: phaseLabel = "Downloading model"
        case .loadingModel: phaseLabel = "Loading model"
        case .ready: return "Ready"
        }
        guard elapsedSeconds >= Self.heartbeatRevealThreshold else { return phaseLabel }
        return "\(phaseLabel) · \(elapsedSeconds)s"
    }
}
