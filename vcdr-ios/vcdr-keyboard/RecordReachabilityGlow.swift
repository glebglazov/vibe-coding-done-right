import SwiftUI

/// The record control's lit/unlit treatment: a halo when the next tap records
/// in place, a dimmed pill when it will open the app instead.
///
/// Binary by design. Recording and transcribing have their own pills, so this
/// says one thing only — whether the tap redirects.
///
/// The halo is one-sided: light off the bottom and lower flanks, nothing above.
/// The extension's top edge is a system clip we do not own, and the record pill
/// sits a couple of points below it in the Full strip, so an even spread gets
/// sheared there and reads as a straight line along the top of the pill. Buying
/// room above the pill would mean growing the keyboard, which is not ours to
/// spend; shaping the light downward costs nothing, because below the strip
/// nothing clips at all.
struct RecordReachabilityGlow: ViewModifier {

    // MARK: - Constants

    /// Halo spread. Wide enough to read as light coming off the pill rather
    /// than as a border, which the pill already has. Wider than an even spread
    /// would need, and at full opacity, because roughly the top half of the
    /// halo is masked away and the rest has to carry the same brightness.
    private static let haloRadius: CGFloat = 8.5
    private static let haloOpacity: Double = 1
    /// How far the light source sits below the pill, which is what tips the
    /// remaining halo downward rather than leaving it centred and cropped.
    private static let haloOffset: CGFloat = 3
    /// Room around the pill for the blur to spread into. A mask only draws
    /// within its own bounds, so without this the mask would crop the halo at
    /// the pill's edges — undoing the blur it is there to shape.
    private static let haloSpill: CGFloat = haloRadius * 3 + haloOffset
    /// How far the unlit pill drops back. It stays a tappable control — the
    /// tap still works, it just leaves the keyboard — so it dims rather than
    /// fading towards disabled.
    private static let unlitOpacity: Double = 0.55
    /// Reachability flips on a poll, not on a gesture, so the change is eased
    /// instead of snapping under a thumb that did nothing.
    private static let transition: Animation = .easeInOut(duration: 0.2)

    let isLit: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(halo)
            .opacity(isLit ? 1 : Self.unlitOpacity)
            .animation(Self.transition, value: isLit)
    }

    private var halo: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(color)
                .offset(y: Self.haloOffset)
                .blur(radius: Self.haloRadius)
                .padding(-Self.haloSpill)
                .mask(downwardMask(pillHeight: geometry.size.height))
        }
        .opacity(isLit ? Self.haloOpacity : 0)
        .allowsHitTesting(false)
    }

    /// Clear where the pill's top edge is and at full strength by its vertical
    /// middle, ramping between the two. The ramp is what keeps the fix honest:
    /// a hard cut at the top edge would trade the long straight line for two
    /// short ones beside the pill's top corners.
    private func downwardMask(pillHeight: CGFloat) -> some View {
        let height = pillHeight + Self.haloSpill * 2
        return LinearGradient(
            stops: [
                .init(color: .clear, location: Self.haloSpill / height),
                .init(
                    color: .black,
                    location: (Self.haloSpill + pillHeight / 2) / height
                )
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    func recordReachabilityGlow(isLit: Bool, color: Color) -> some View {
        modifier(RecordReachabilityGlow(isLit: isLit, color: color))
    }
}
