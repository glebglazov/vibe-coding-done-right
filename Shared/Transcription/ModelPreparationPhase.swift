import Foundation

/// What the transcription model is doing while it gets ready. One vocabulary
/// for both products, so macOS and iOS cannot word the same wait differently.
enum ModelPreparationPhase: Sendable, Equatable {
    /// Initialization has not begun.
    case preparing
    /// Another model is preparing, and this one is kept back until that one
    /// finishes. Its own phase because a model held back is neither idle nor
    /// under way, and a surface that said either would be lying to whoever is
    /// waiting on it.
    case waitingItsTurn
    /// Artifacts are being fetched. A launch that finds them already cached
    /// never enters this phase, and so must never claim to be downloading.
    case downloadingModel
    /// Artifacts are on disk, being compiled and loaded.
    case loadingModel
    case ready
    /// Preparation stopped and waiting will not restart it. The failure rides
    /// on the phase because only the failing step knows what went wrong; every
    /// surface downstream reads it from here instead of a status string.
    case failed(PreparationFailure)
}

/// Why model preparation stopped. Only causes the app can genuinely tell apart
/// are named: the transcription backend reports failures as opaque text, so
/// anything that is not a lost connection is reported as itself rather than
/// paraphrased into a cause nobody verified.
enum PreparationFailure: Sendable, Equatable {
    case offline
    case unknown
}

extension PreparationFailure {
    /// The URL-loading codes that mean the device had no usable connection.
    /// Everything else — a timeout, a bad payload, a CoreML compile error —
    /// stays unknown, because it could be the network or could be the model.
    private static let offlineURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff
    ]

    nonisolated init(error: Error) {
        let nsError = error as NSError
        let isOffline = nsError.domain == NSURLErrorDomain
            && Self.offlineURLErrorCodes.contains(nsError.code)
        self = isOffline ? .offline : .unknown
    }

    /// What went wrong, in one line.
    var headline: String {
        switch self {
        case .offline: "The model download needs an internet connection"
        case .unknown: "The model could not be prepared"
        }
    }

    /// What clears it. Every failure retries; only a lost connection is worth
    /// asking the user to fix first, because it is the only cause the app knows.
    var remedy: String {
        switch self {
        case .offline: "Waiting will not fix this — reconnect, then try again."
        case .unknown: "Waiting will not fix this — try again."
        }
    }

    /// The whole failure for surfaces that show one line.
    var message: String { "\(headline). \(remedy)" }

    /// The word a status badge has room for.
    var badge: String {
        switch self {
        case .offline: "Offline"
        case .unknown: "Failed"
        }
    }
}

extension ModelPreparationPhase {
    /// Seconds a phase must last before its label gains a Preparation
    /// Heartbeat. Fast preparations stay quiet; slow ones get a visible tick.
    static let heartbeatRevealThreshold: Int = 2

    /// What a readiness surface says before the provider has reported a phase:
    /// the opening phase, with no Preparation Heartbeat accrued yet.
    static let initialLabel = ModelPreparationPhase.preparing.label(elapsedSeconds: 0)

    /// The label every readiness surface renders for this phase. Past the
    /// reveal threshold it carries a Preparation Heartbeat — the seconds spent
    /// in the phase — because the transcription backend reports no progress of
    /// its own, so elapsed time is the only honest number available.
    func label(elapsedSeconds: Int) -> String {
        let phaseLabel: String
        switch self {
        case .preparing: phaseLabel = "Preparing"
        case .waitingItsTurn: phaseLabel = "Waiting its turn"
        case .downloadingModel: phaseLabel = "Downloading model"
        case .loadingModel: phaseLabel = "Loading model"
        case .ready: return "Ready"
        case .failed(let failure): return failure.headline
        }
        guard elapsedSeconds >= Self.heartbeatRevealThreshold else { return phaseLabel }
        return "\(phaseLabel) · \(elapsedSeconds)s"
    }
}
