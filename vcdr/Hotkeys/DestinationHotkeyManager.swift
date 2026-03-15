import Foundation
import ApplicationServices
import OSLog

/// Manages a single CGEvent tap that watches for multiple destination hotkey bindings.
/// Uses **superset modifier matching**: if a destination is Ctrl+C and the user presses
/// Ctrl+Cmd+Option+C (because push-to-talk modifiers are held), it still matches.
/// This naturally handles push-to-talk (extra modifiers) and toggle mode (no extra modifiers).
final class DestinationHotkeyManager {
    private let tap = EventTapManager()
    private var bindings: [(id: UUID, keyCode: CGKeyCode, modifiers: CGEventFlags)] = []

    /// When false, matched key events pass through unconsumed.
    var isEnabled: Bool = false

    /// Called when a destination hotkey is matched. Receives the destination UUID.
    var onDestinationMatched: ((UUID) -> Void)?

    // MARK: - Registration

    func register(bindings: [(UUID, HotkeyBinding)]) {
        unregister()

        self.bindings = bindings.compactMap { id, hotkey in
            guard hotkey.isAssigned else { return nil }
            return (id: id, keyCode: CGKeyCode(hotkey.keyCode), modifiers: CGEventFlags(rawValue: hotkey.modifiers))
        }

        guard !self.bindings.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            Logger.hotkeys.warning("DestinationHotkeyManager: accessibility not granted")
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let installed = tap.install(
            eventMask: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<DestinationHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if !installed {
            Logger.hotkeys.error("DestinationHotkeyManager: failed to create event tap")
            return
        }

        Logger.hotkeys.info("DestinationHotkeyManager: registered \(self.bindings.count) bindings")
    }

    func unregister() {
        tap.uninstall()
        bindings = []
    }

    // MARK: - Event Handling

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.hotkeys.warning("DestinationHotkeyManager: tap disabled, re-enabling")
            tap.reEnableTap()
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Skip auto-repeat events
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        // Superset matching: event flags must contain all binding modifiers (extras are OK)
        for binding in bindings {
            if keyCode == binding.keyCode && flags.intersection(binding.modifiers) == binding.modifiers {
                Logger.hotkeys.debug("DestinationHotkeyManager: matched destination \(binding.id)")
                onDestinationMatched?(binding.id)
                return nil // Consume the event
            }
        }

        return Unmanaged.passUnretained(event)
    }

    deinit { unregister() }
}
