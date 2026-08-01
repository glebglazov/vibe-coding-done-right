import SwiftUI

/// The red wash the keyboard paints *around* the Stop pill while the Discard
/// Warning ramps. It is drawn outside the control because a thumb sits on the
/// pill, and because the pill has to keep naming what release does — release
/// still stops (ADR-0004). The wash sweeps across the strip rather than
/// tinting it uniformly, so it is also the "how much longer" cue: the pill has
/// no progress fill of its own, since one under the thumb cannot be read.
///
/// Both keyboard states use the same wash so their escalation reads alike; what
/// differs is what it sits on. The Full toolbar strip is opaque, so tinting it
/// is unremarkable. Compact deliberately paints no background at all, so the
/// wash is the one thing that ever covers the host app there — which is
/// tolerable only because it exists for the duration of a hold and no longer.
struct DiscardWarningWash: ViewModifier {

    /// Opacity of the wash at the very end of the warning, a moment before
    /// Discard fires.
    static let maxOpacity: Double = 0.4

    var progress: CGFloat

    func body(content: Content) -> some View {
        content.background(
            DiscardWarningWipe(
                color: .red,
                progress: progress,
                opacity: Double(progress) * Self.maxOpacity
            )
        )
    }
}

extension View {
    /// Sweeps red across this surface in step with the Discard Warning. At
    /// progress 0 nothing is drawn at all, so a Compact row at rest still shows
    /// the host app through.
    func discardWarningWash(progress: CGFloat) -> some View {
        modifier(DiscardWarningWash(progress: progress))
    }
}

/// Holds a keyboard state's wash progress and owns the two rules both states
/// share: the wash follows the warning ramp up, and the way it retreats
/// differs by why the hold ended. Release before the threshold is the
/// recovery gesture — it has to read as *gone*, not as fading — while
/// Discard's unwind overlaps the CANCELLED flash and can afford to be
/// slower. Device verification (task 07) found a uniform 200ms retreat read
/// as lingering on release; this is the split that replaced it.
@MainActor
@Observable
final class DiscardWarningWashState {
    /// Release before the threshold: fast enough to look instant, slow
    /// enough that a wash at max opacity doesn't leave a hard flash edge.
    static let releaseFadeDuration: Double = 0.09
    /// Discard: overlaps the CANCELLED flash and has a different job, so it
    /// keeps the longer, original pace.
    static let discardFadeDuration: Double = 0.2

    private(set) var progress: CGFloat = 0

    func ramp(to warningProgress: CGFloat) {
        progress = warningProgress
    }

    /// Called when a hold is released before the Discard threshold — straight
    /// from the gesture's release, not only from the pill's `isWarning`
    /// `onChange`, which lands a render pass later. Idempotent, so a later
    /// no-op call from that `onChange` is harmless.
    func end() {
        reset(duration: Self.releaseFadeDuration)
    }

    /// Called synchronously from the Discard callback, before it does
    /// anything else (in particular before `dictationState` moves the pill
    /// out of existence), so the unwind starts on fire rather than being
    /// left to an `onChange` on a view that may already be gone.
    func beginDiscardUnwind() {
        reset(duration: Self.discardFadeDuration)
    }

    /// `guard progress > 0` makes repeat calls a no-op, so whichever of
    /// `end()`, `beginDiscardUnwind()`, and a belt-and-braces
    /// `dictationState` watcher runs first wins.
    private func reset(duration: Double) {
        guard progress > 0 else { return }
        withAnimation(.easeOut(duration: duration)) {
            progress = 0
        }
    }
}
