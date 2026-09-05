import Foundation

/// A live claim on one key combination, handed out by a `HotkeyRegistry`.
///
/// Holding the handle *is* holding the claim: while it lives the combination
/// belongs to VCDR, and releasing it hands the combination back to the frontmost
/// app. There is deliberately no enable/disable — the registry's mechanism has no
/// pass-through, so a claimed combination is always consumed and the only way to
/// let one through is to stop claiming it.
final class HotkeyClaim {
    private var onRelease: (() -> Void)?

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    /// Releases the claim now. Idempotent.
    ///
    /// Re-claiming a combination must go through this rather than through dropping
    /// the last reference: the window server refuses a second registration of a
    /// combination that is still claimed, so the release has to land *before* the
    /// new claim is made, and `deinit` alone cannot promise that ordering.
    func release() {
        guard let onRelease else { return }
        self.onRelease = nil
        onRelease()
    }

    deinit { release() }
}
