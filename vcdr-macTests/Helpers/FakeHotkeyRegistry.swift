import Foundation
@testable import vcdr_mac

/// Test double for `HotkeyRegistry`. Records what is claimed and delivers a press
/// to the claim holding a combination.
///
/// This is what lets a test drive a hotkey at all: the event tap the rest of the
/// app's hotkeys use cannot be installed without an Accessibility grant, so before
/// this seam existed the nearest a test could get was asserting what a tap
/// *targeted*.
@MainActor
final class FakeHotkeyRegistry: HotkeyRegistry {

    private struct Entry {
        let binding: HotkeyBinding
        let onPress: () -> Void
    }

    private var entries: [Int: Entry] = [:]
    private var lastIssuedID = 0

    /// Every combination currently claimed, oldest claim first.
    var claimedBindings: [HotkeyBinding] {
        entries.keys.sorted().compactMap { entries[$0]?.binding }
    }

    func claim(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyClaim? {
        lastIssuedID += 1
        let id = lastIssuedID
        entries[id] = Entry(binding: binding, onPress: onPress)
        return HotkeyClaim { [weak self] in self?.entries[id] = nil }
    }

    /// Presses `binding` as the system would.
    /// - Returns: `false` when nothing claims that combination.
    @discardableResult
    func press(_ binding: HotkeyBinding) -> Bool {
        guard let entry = entries.values.first(where: { $0.binding == binding }) else { return false }
        entry.onPress()
        return true
    }
}
