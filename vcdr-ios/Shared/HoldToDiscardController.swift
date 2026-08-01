import Foundation

/// A hold that ended by release rather than by reaching the threshold.
///
/// Carries how far into the Discard Warning the hold got so a surface can ease
/// its treatment out from where it actually was. `id` changes on every
/// abandonment so repeated releases at the same ramp position still register
/// as distinct events for `onChange`.
struct HoldAbandonment: Equatable {
    let warningProgress: CGFloat
    let id: Int
}

/// Drives the hold-Stop-to-Discard interaction: a silent Discard Dwell from
/// touch-down, then the Discard Warning ramping across the rest of the hold,
/// normal Stop on release at any point before the Hold Threshold, and Discard
/// at the threshold without waiting for release (ADR-0004).
@MainActor
@Observable
final class HoldToDiscardController {
    // MARK: - Constants

    /// Total hold before Discard fires. The keyboard's Discard path derives its
    /// own timing from this constant so the two can never drift apart.
    static let holdDuration: TimeInterval = 3
    /// Opening stretch of a hold during which nothing at all is shown.
    static let dwellDuration: TimeInterval = 1
    /// Stretch over which the Discard Warning ramps 0→1, ending at discard.
    static var warningDuration: TimeInterval { holdDuration - dwellDuration }
    static let cancelledFlashDuration: TimeInterval = 1
    static let progressTick: Duration = .milliseconds(16)
    /// Discrete jumps the progress indicator takes under Reduce Motion,
    /// instead of the continuous-looking per-tick sweep. The colour ramp is
    /// unaffected by this — a fade isn't motion.
    static let reduceMotionSteps = 10

    // MARK: - State

    var isHolding = false
    /// Whether the Discard Warning is showing — false for the whole dwell.
    var isWarning = false
    /// 0→1 position *within the warning window*, not within the whole hold.
    var warningProgress: CGFloat = 0
    /// Set when a hold ends by release instead of reaching the threshold.
    var abandonment: HoldAbandonment?

    private var holdStart: Date?
    private var discardTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didDiscard = false
    private var abandonmentCount = 0

    private let onStop: () -> Void
    private let onDiscard: () -> Void
    private let onDiscardHaptic: () -> Void
    private let onWarningRamp: (CGFloat) -> Void

    init(
        onStop: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onDiscardHaptic: @escaping () -> Void = {},
        onWarningRamp: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.onStop = onStop
        self.onDiscard = onDiscard
        self.onDiscardHaptic = onDiscardHaptic
        self.onWarningRamp = onWarningRamp
    }

    func touchDown() {
        guard !isHolding else { return }
        didDiscard = false
        isHolding = true
        isWarning = false
        warningProgress = 0
        holdStart = Date()

        discardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled, let self else { return }
            self.fireDiscard()
        }

        progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.tickProgress()
                if self.warningProgress >= 1 { break }
                try? await Task.sleep(for: Self.progressTick)
            }
        }
    }

    func touchUp() {
        let reachedProgress = warningProgress

        discardTask?.cancel()
        discardTask = nil
        progressTask?.cancel()
        progressTask = nil
        isHolding = false
        isWarning = false
        warningProgress = 0
        holdStart = nil

        if !didDiscard {
            abandonmentCount += 1
            abandonment = HoldAbandonment(warningProgress: reachedProgress, id: abandonmentCount)
            onStop()
        }
        didDiscard = false
    }

    /// Discards immediately, independent of hold state — including with no
    /// hold in progress at all. Produces the same terminal outcome as a
    /// completed hold. This is the only thing the "Discard recording"
    /// accessibility action calls: a three-second sustained hold is a poor
    /// primary gesture for VoiceOver or limited motor control, and it must
    /// never be the *only* route to Discard.
    func discardImmediately() {
        discardTask?.cancel()
        discardTask = nil
        fireDiscard()
    }

    private func tickProgress() {
        guard let holdStart else { return }
        let elapsed = Date().timeIntervalSince(holdStart)
        guard elapsed >= Self.dwellDuration else { return }

        isWarning = true
        warningProgress = min(1, CGFloat((elapsed - Self.dwellDuration) / Self.warningDuration))
        onWarningRamp(warningProgress)
    }

    private func fireDiscard() {
        guard !didDiscard else { return }
        didDiscard = true
        isHolding = false
        isWarning = false
        warningProgress = 1
        progressTask?.cancel()
        progressTask = nil
        onDiscardHaptic()
        onDiscard()
    }
}

extension CGFloat {
    /// Quantizes 0...1 progress into discrete steps, for Reduce Motion: a
    /// driven sweep (the ring trim, the pill fill) reads as a handful of
    /// jumps instead of continuous-looking motion. Not used for colour —
    /// the Discard Warning tint stays a continuous fade under Reduce Motion,
    /// since a fade isn't motion.
    func steppedForReduceMotion(steps: Int = HoldToDiscardController.reduceMotionSteps) -> CGFloat {
        guard steps > 0 else { return self }
        return (self * CGFloat(steps)).rounded(.down) / CGFloat(steps)
    }
}
