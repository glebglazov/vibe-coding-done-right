import Foundation

/// A live Suspension of every claim a `SuspendableHotkeyRegistry` holds.
///
/// Holding the token *is* holding the Suspension: while it lives, every VCDR
/// combination belongs to the frontmost app — which is what lets the shortcut
/// recorder read a combination the app has bound. When the token goes away the
/// claims come back on their own, so a screen that vanishes without tidying up
/// cannot leave the app deaf.
final class HotkeySuspension {
    private var onRelease: (() -> Void)?

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    /// Ends this Suspension now. Idempotent.
    func release() {
        guard let onRelease else { return }
        self.onRelease = nil
        onRelease()
    }

    deinit { release() }
}
