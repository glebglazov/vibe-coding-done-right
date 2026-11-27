import Foundation

/// One Recording Run's identity. A late event names the run it was made for,
/// so it can be dropped when that run is no longer the one it would act on.
nonisolated struct RunID: Hashable, Sendable {
    private let raw = UUID()
}

/// Proof that a run holds the microphone capture. `startCapture` hands one
/// out only when the run still wanted the capture when the engine came up.
nonisolated struct CaptureLease: Hashable, Sendable {
    let run: RunID
}

/// The audio engine stopped without anyone asking: an interruption (a call,
/// Siri, an alarm) or a route change whose restart failed.
nonisolated struct EngineLoss: Sendable {
    /// The capture the loss cut, or nil when no run was capturing.
    let lease: CaptureLease?
    let reason: String
}
