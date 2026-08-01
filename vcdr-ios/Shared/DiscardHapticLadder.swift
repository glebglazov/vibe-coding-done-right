import Foundation

/// The accelerating tick pattern of the Discard Warning, expressed as ramp
/// positions rather than as times.
///
/// The warning's visual ramp is already driven by `HoldToDiscardController`'s
/// tick, so the ladder rides that same signal: feed it every ramp value and it
/// emits the ticks whose positions have been passed. A second timer alongside
/// the controller's would be free to drift away from what the eye sees.
///
/// A thumb covers the control it is holding, so the ladder is the part of the
/// warning that still lands when the visuals are hidden.
struct DiscardHapticLadder {
    /// Gap between the first two ticks, at the dwell boundary.
    static let startInterval: TimeInterval = 0.35
    /// Gap between the last two ticks, as Discard approaches.
    static let endInterval: TimeInterval = 0.12

    /// Ramp positions (0→1 within the warning window) at which a tick fires.
    /// The first is 0 — the dwell boundary itself gets a tick.
    static let tickPositions: [CGFloat] = {
        let duration = HoldToDiscardController.warningDuration
        var positions: [CGFloat] = []
        var elapsed: TimeInterval = 0
        while elapsed < duration {
            let position = elapsed / duration
            positions.append(CGFloat(position))
            elapsed += startInterval + (endInterval - startInterval) * position
        }
        return positions
    }()

    private var nextTick = 0

    /// Number of ticks owed by `progress`, given everything already emitted.
    /// Advances the ladder, so each position pays out once per hold.
    mutating func ticks(upTo progress: CGFloat) -> Int {
        var count = 0
        while nextTick < Self.tickPositions.count, progress >= Self.tickPositions[nextTick] {
            nextTick += 1
            count += 1
        }
        return count
    }

    /// Rewinds to the dwell boundary so the next hold starts from silence.
    mutating func reset() {
        nextTick = 0
    }
}

/// Reference wrapper so a view's ramp closure — handed to the controller at
/// init, before any `@State` exists — and the view body can advance the same
/// ladder.
@MainActor
final class HapticLadderBox {
    private var ladder = DiscardHapticLadder()

    func ticks(upTo progress: CGFloat) -> Int {
        ladder.ticks(upTo: progress)
    }

    func reset() {
        ladder.reset()
    }
}
