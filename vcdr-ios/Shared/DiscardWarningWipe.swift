import SwiftUI

/// The Discard Warning's progress, drawn as red advancing left→right across a
/// surface the thumb does not cover.
///
/// Progress used to live on the control itself — a ring at the button's radius,
/// a fill sweep inside the pill — which is precisely where the holding thumb
/// sits, so the one cue that answered "how much longer" was invisible while it
/// mattered. Here the surface behind the control carries it instead: how far
/// the red has travelled *is* the progress.
struct DiscardWarningWipe: View {

    /// Width of the falloff at the advancing edge. Wide enough that the red
    /// reads as a wash sweeping in rather than a rectangle growing.
    static let softEdgeWidth: CGFloat = 56

    let color: Color
    /// 0…1 position within the Discard Warning. At 0 nothing is drawn at all,
    /// which is what keeps the Discard Dwell silent.
    let progress: CGFloat
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion applies to the sweep only: the travelling edge is driven
    /// geometry, so it steps. Opacity is a fade, not motion, so it does not.
    private var sweep: CGFloat {
        let clamped = min(max(progress, 0), 1)
        return reduceMotion ? clamped.steppedForReduceMotion() : clamped
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * sweep
            if width > 0 {
                color
                    .frame(width: width)
                    .mask(softEdge(width: width))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    private func softEdge(width: CGFloat) -> some View {
        let band = min(Self.softEdgeWidth, width)
        return LinearGradient(
            stops: [
                .init(color: .black, location: (width - band) / width),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
