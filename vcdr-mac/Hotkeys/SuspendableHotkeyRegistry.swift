import Foundation

/// A `HotkeyRegistry` that can hand every combination it holds back to the
/// system at once, and take exactly those back afterwards.
///
/// The shortcut recorder needs this. A claim has no pass-through, so the only
/// way the combination the user is pressing reaches the recorder is for nothing
/// in VCDR to claim it — and every hotkey owner in the app is affected at once,
/// by something none of them can see. Suspension is therefore one operation on
/// the registry they all share: an owner claims and releases as its own state
/// dictates, and this decides whether a claim is live right now.
@MainActor
final class SuspendableHotkeyRegistry: HotkeyRegistry {

    /// One combination an owner asked for. `live` is the claim on the wrapped
    /// registry, and is nil exactly while a Suspension is held.
    private struct Claimed {
        let binding: HotkeyBinding
        let onPress: () -> Void
        var live: HotkeyClaim?
    }

    private let base: any HotkeyRegistry
    private var claimed: [Int: Claimed] = [:]
    private var lastIssuedID = 0

    /// Suspensions nest, and the combinations come back when the last token is
    /// gone — a second recorder opened over the first cannot cut its Suspension
    /// short by closing early.
    private var heldSuspensions = 0

    init(wrapping base: any HotkeyRegistry) {
        self.base = base
    }

    // MARK: - HotkeyRegistry

    /// Claims through the wrapped registry, or records the claim and waits when a
    /// Suspension is held — a shortcut re-bound in the recorder is then armed as
    /// its new combination the moment the recorder closes, with no owner knowing
    /// its claim was deferred.
    func claim(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyClaim? {
        var entry = Claimed(binding: binding, onPress: onPress, live: nil)
        if heldSuspensions == 0 {
            guard let live = base.claim(binding, onPress: onPress) else { return nil }
            entry.live = live
        }

        lastIssuedID += 1
        let id = lastIssuedID
        claimed[id] = entry
        return HotkeyClaim { [weak self] in self?.release(id) }
    }

    // MARK: - Suspension

    /// Hands every claimed combination back for as long as the returned token is
    /// held. Releasing it re-claims whatever is owned at that moment, so an
    /// owner's own arming state decides the set that comes back and nothing has
    /// to remember what was live before.
    func suspend() -> HotkeySuspension {
        heldSuspensions += 1
        if heldSuspensions == 1 {
            for id in claimed.keys.sorted() {
                claimed[id]?.live?.release()
                claimed[id]?.live = nil
            }
        }
        return HotkeySuspension { [weak self] in self?.endSuspension() }
    }

    private func endSuspension() {
        heldSuspensions -= 1
        guard heldSuspensions == 0 else { return }

        for id in claimed.keys.sorted() {
            guard let entry = claimed[id] else { continue }
            claimed[id]?.live = base.claim(entry.binding, onPress: entry.onPress)
        }
    }

    private func release(_ id: Int) {
        claimed.removeValue(forKey: id)?.live?.release()
    }
}
