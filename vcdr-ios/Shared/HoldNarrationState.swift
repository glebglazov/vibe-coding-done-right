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

    func ramp(to progress: CGFloat) {
        warningProgress = progress
    }

    func end() {
        warningProgress = nil
    }
}
