import Foundation
import Carbon
import ApplicationServices
import OSLog

final class GlobalHotkeyManager {
    private let tap = EventTapManager()

    private var targetKeyCode: CGKeyCode = 0
    private var targetModifiers: CGEventFlags = []
    private(set) var isHotkeyActive = false

    /// When false, matched key events pass through unconsumed.
    /// Key-up still resets `isHotkeyActive` to keep internal state consistent.
    var isEnabled: Bool = true

    /// Orthogonal to `isEnabled`. Set while the user is recording a new shortcut
    /// in the UI so the hotkey passes through unconsumed without disturbing the
    /// managed `isEnabled` state.
    var isSuppressed: Bool = false

    /// Called synchronously from the CGEvent tap callback (no GCD dispatch).
    /// This runs on the main thread during the run loop's event source processing,
    /// bypassing both DispatchQueue.main.async and MainActor Task scheduling — both
    /// of which can be delayed by seconds when the MainActor executor is stalled.
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func register(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        unregister()

        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers

        guard AXIsProcessTrusted() else {
            Logger.hotkeys.warning("Accessibility permissions not granted")
            requestAccessibilityPermissions()
            return false
        }

        let eventMask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))

        let installed = tap.install(
            eventMask: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard installed else {
            Logger.hotkeys.error("Failed to create event tap")
            return false
        }

        let display = Self.shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)
        Logger.hotkeys.info("Hotkey registered: \(display)")
        return true
    }

    func unregister() {
        guard tap.isInstalled else { return }
        tap.uninstall()
        Logger.hotkeys.info("Hotkey unregistered")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.hotkeys.warning("Event tap disabled, re-enabling")
            tap.reEnableTap()

            // If the hotkey was active but the key is no longer physically held,
            // we missed the key-up while the tap was disabled. Fire it now.
            if isHotkeyActive {
                let keyStillDown = CGEventSource.keyState(.combinedSessionState, key: targetKeyCode)
                if !keyStillDown {
                    Logger.hotkeys.warning("Recovering missed key-up after tap re-enable")
                    isHotkeyActive = false
                    if isEnabled && !isSuppressed {
                        onKeyUp?()
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        if type == .keyDown {
            Logger.hotkeys.notice("[tap] keyDown kc=\(keyCode) flags=\(flags.rawValue) | target kc=\(self.targetKeyCode) flags=\(self.targetModifiers.rawValue) | en=\(self.isEnabled) sup=\(self.isSuppressed)")
            guard keyCode == targetKeyCode && flags == targetModifiers else {
                return Unmanaged.passUnretained(event)
            }
            guard isEnabled && !isSuppressed else { return Unmanaged.passUnretained(event) }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                isHotkeyActive = true
                Logger.hotkeys.debug("[tap] keyDown fired, isHotkeyActive=true")
                // Call onKeyDown synchronously — the CGEvent tap callback already
                // runs on the main thread (main run loop). DispatchQueue.main.async
                // and Task scheduling can be delayed by seconds when the MainActor
                // executor is stalled.
                self.onKeyDown?()
            }
            return nil
        } else if type == .keyUp {
            // Match keyUp by keyCode only — modifiers may already be released
            guard keyCode == targetKeyCode && isHotkeyActive else {
                return Unmanaged.passUnretained(event)
            }
            // Must reset isHotkeyActive even when disabled to keep state consistent
            isHotkeyActive = false
            guard isEnabled && !isSuppressed else { return Unmanaged.passUnretained(event) }
            Logger.hotkeys.debug("[tap] keyUp fired, calling onKeyUp synchronously")
            // Call onKeyUp synchronously — NOT through DispatchQueue.main.async.
            // The CGEvent tap callback already runs on the main thread (main run loop).
            // Dispatching through GCD or Tasks adds latency that can reach seconds
            // when the MainActor executor is stalled.
            self.onKeyUp?()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func shortcutDisplayString(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("\u{2303}") }
        if modifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
        if modifiers.contains(.maskShift) { parts.append("\u{21E7}") }
        if modifiers.contains(.maskCommand) { parts.append("\u{2318}") }
        parts.append(keyNameForCode(keyCode))
        return parts.joined()
    }

    static func keyNameForCode(_ keyCode: CGKeyCode) -> String {
        KeyCodeMap.name(for: keyCode)
    }

    var isRegistered: Bool { tap.isInstalled }

    deinit { unregister() }
}
