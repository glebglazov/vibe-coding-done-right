import Foundation
import Carbon
import ApplicationServices
import OSLog

final class GlobalHotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var targetKeyCode: CGKeyCode = 0
    private var targetModifiers: CGEventFlags = []
    private(set) var isHotkeyActive = false

    /// When false, matched key events pass through unconsumed.
    /// Key-up still resets `isHotkeyActive` to keep internal state consistent.
    var isEnabled: Bool = true

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

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            Logger.hotkeys.error("Failed to create event tap")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let display = Self.shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)
        Logger.hotkeys.info("Hotkey registered: \(display)")
        return true
    }

    func unregister() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
            Logger.hotkeys.info("Hotkey unregistered")
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.hotkeys.warning("Event tap disabled, re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        if type == .keyDown {
            guard keyCode == targetKeyCode && flags == targetModifiers else {
                return Unmanaged.passUnretained(event)
            }
            guard isEnabled else { return Unmanaged.passUnretained(event) }
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
            guard isEnabled else { return Unmanaged.passUnretained(event) }
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

    // TODO: This mapping assumes a US ANSI keyboard layout. Key codes are hardware
    // constants, so e.g. code 44 is "/" on US but a different character on other layouts.
    // Two options to fix: (1) use UCKeyTranslate / TISCopyCurrentKeyboardInputSource to
    // resolve key codes dynamically based on the active input source, or (2) capture the
    // character from the NSEvent at recording time and store it alongside the key code.
    static func keyNameForCode(_ keyCode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            // Letters
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            // Numbers
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            25: "9", 26: "7", 28: "8", 29: "0",
            // Punctuation
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            // Special keys
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
            // Arrow keys
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }

    var isRegistered: Bool { eventTap != nil }

    deinit { unregister() }
}
