import SwiftUI

/// The red wash the keyboard paints *around* the Stop pill while the Discard
/// Warning ramps. It is drawn outside the control because a thumb sits on the
/// pill, and because the pill has to keep naming what release does — release
/// still stops (ADR-0004). The pill's own fill sweep stays the precise
/// "how much longer" cue.
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

    /// How long the wash takes to ease away once a hold ends.
    static let fadeDuration: Double = 0.2

    var progress: CGFloat

    func body(content: Content) -> some View {
        content.background(
            Color.red
                .opacity(Double(progress) * Self.maxOpacity)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    /// Washes this surface red in step with the Discard Warning. At progress 0
    /// the wash is fully transparent, so a Compact row at rest still shows the
    /// host app through.
    func discardWarningWash(progress: CGFloat) -> some View {
        modifier(DiscardWarningWash(progress: progress))
    }
}

/// Holds a keyboard state's wash progress and owns the one rule both states
/// share: the wash follows the warning ramp up, and eases out rather than
/// snapping when a hold ends, so backing out reads as intentional.
@MainActor
@Observable
final class DiscardWarningWashState {
    private(set) var progress: CGFloat = 0

    func ramp(to warningProgress: CGFloat) {
        progress = warningProgress
    }

    /// Called when the warning ends for any reason — released mid-warning, or
    /// Discard fired at the threshold and the flash takes over.
    func end() {
        guard progress > 0 else { return }
        withAnimation(.easeOut(duration: DiscardWarningWash.fadeDuration)) {
            progress = 0
        }
    }
}
