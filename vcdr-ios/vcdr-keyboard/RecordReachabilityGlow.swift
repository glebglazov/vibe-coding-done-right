import SwiftUI

/// The record control's lit/unlit treatment: a halo when the next tap records
/// in place, a dimmed pill when it will open the app instead.
///
/// Binary by design. Recording and transcribing have their own pills, so this
/// says one thing only — whether the tap redirects.
struct RecordReachabilityGlow: ViewModifier {

    // MARK: - Constants

    /// Halo spread. Wide enough to read as light coming off the pill rather
    /// than as a border, which the pill already has.
    private static let haloRadius: CGFloat = 7
    private static let haloOpacity: Double = 0.85
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
            .opacity(isLit ? 1 : Self.unlitOpacity)
            .shadow(
                color: isLit ? color.opacity(Self.haloOpacity) : .clear,
                radius: isLit ? Self.haloRadius : 0
            )
            .animation(Self.transition, value: isLit)
    }
}

extension View {
    func recordReachabilityGlow(isLit: Bool, color: Color) -> some View {
        modifier(RecordReachabilityGlow(isLit: isLit, color: color))
    }
}
