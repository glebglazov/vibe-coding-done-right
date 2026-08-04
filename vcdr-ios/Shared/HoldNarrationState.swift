import Foundation

/// Where the current hold's Discard Warning has got to, for the reserved row
/// to narrate.
///
/// Kept apart from the surfaces' wash/tint progress on purpose: that progress
/// eases *out* after a hold ends, which is right for colour and wrong for
/// words. A countdown that keeps counting for 90ms after release, or a
/// "Release to keep" that outlives the release, is a lie. Non-nil here means
/// a hold is ramping *now*.
@MainActor
@Observable
final class HoldNarrationState {
    /// nil for the whole Discard Dwell — the controller reports no ramp before
    /// it — and nil again the instant the hold ends, by release or by firing.
    private(set) var warningProgress: CGFloat?

    /// True from a short way into the dwell until the hold ends: the words are
    /// on screen before the warning ramps, which is the only way a hint about
    /// what the hold does can be read before the hold does it. Stays true for
    /// the warning too — a ramp is a hold that is still being narrated.
    private(set) var isHinting = false

    func beginHint() {
        isHinting = true
    }

    func ramp(to progress: CGFloat) {
        isHinting = true
        warningProgress = progress
    }

    func end() {
        isHinting = false
        warningProgress = nil
    }
}
