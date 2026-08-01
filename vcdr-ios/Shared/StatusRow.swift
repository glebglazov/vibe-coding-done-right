import SwiftUI

/// The reserved one-line row both surfaces carry: above the dictation controls
/// on the keyboard, at the top of the app's recording screen.
///
/// `height` is fixed and is the single constant both surfaces size themselves
/// from — `CompactKeyboardView.intrinsicHeight` folds it into the pinned
/// Compact frame and `KeyboardDisplayModeManager.fullToolbarHeight` into the
/// Full strip — so no phase, no tenant and no Dynamic Type setting can change
/// the extension's height or reflow the recording screen. Content comes from
/// `StatusRowContent`; only the type size and colour differ per surface.
struct StatusRow: View {

    // MARK: - Constants

    /// Reserved whether or not there is anything to say.
    static let height: CGFloat = 20
    /// The row honours Dynamic Type up to the point where a taller line would
    /// no longer fit `height`, then stops growing — the row's height is the
    /// hard constraint, so at the largest accessibility sizes the text is
    /// smaller than requested rather than the row being taller than promised.
    private static let maxFontSize: CGFloat = 16
    /// Long content at large type shrinks to fit the width rather than
    /// truncating: a clipped "Release to keep" is worse than a small one.
    private static let minimumScale: CGFloat = 0.6

    var content: String?
    var fontSize: CGFloat
    var color: Color
    /// The hold narration says the same thing as the "Discard recording"
    /// accessibility action already offers, and it changes every second while
    /// a hold runs. Hidden from VoiceOver so a live-changing label can neither
    /// steal focus nor interrupt: nothing here is ever announced.
    var isHoldNarration: Bool

    @ScaledMetric(relativeTo: .caption) private var typeScale: CGFloat = 1

    var body: some View {
        ZStack {
            // Invisible copies of every string the row can hold, so the row
            // claims the width of its widest content once and never has to
            // re-fit as tenants change. Content is centred, and the countdown
            // is composed to a constant length and rendered with monospaced
            // digits, so the ticking line is pinned in place rather than
            // reflowing every second.
            ForEach(StatusRowContent.sizingTexts, id: \.self) { text in
                label(text).hidden()
            }
            if let content {
                label(content)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .accessibilityHidden(isHoldNarration || content == nil)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            // Monospaced digits so the countdown ticking 2→1 changes the glyph
            // and nothing else — a line that reflows every second is worse
            // than no countdown at all.
            .font(.system(size: min(fontSize * typeScale, Self.maxFontSize), weight: .semibold).monospacedDigit())
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumScale)
            .foregroundStyle(color)
    }
}
