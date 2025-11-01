//
//  GlobalHotkeyManager.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import Carbon
import ApplicationServices

struct HotkeyRegistration {
    let name: String
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
    let callback: () -> Void
}

class GlobalHotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeys: [HotkeyRegistration] = []
    private let settings = AppSettings.shared

    func registerHotkeys(hotkeys: [HotkeyRegistration]) -> Bool {
        self.hotkeys = hotkeys

        // Log current shortcut configuration
        print("🔧 Registering global hotkeys:")
        for hotkey in hotkeys {
            let displayString = shortcutDisplayString(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
            print("   \(hotkey.name) - \(displayString)")
        }

        // Check if any shortcuts are set
        if hotkeys.isEmpty {
            print("⚠️ No hotkeys to register")
            return true // Don't fail if no shortcuts are set
        }

        // Check for accessibility permissions
        let isAccessibilityEnabled = AXIsProcessTrusted()
        print("🔐 Accessibility permissions status: \(isAccessibilityEnabled)")

        guard isAccessibilityEnabled else {
            print("❌ Accessibility permissions required for global hotkeys")
            print("💡 Please enable accessibility permissions in System Settings > Privacy & Security > Accessibility")
            requestAccessibilityPermissions()
            return false
        }

        // Create event tap for key down events
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("Failed to create event tap")
            return false
        }

        // Create a run loop source and add it to the current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("✅ Global hotkeys registered successfully!")
        return true
    }

    func unregisterHotkeys() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)

            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }

            self.eventTap = nil
            self.hotkeys = []
            print("Global hotkeys unregistered")
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle the event tap being disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("Event tap disabled, re-enabling...")
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Check if this is our target key combination
        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let relevantFlags = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

            // Check all registered hotkeys
            for hotkey in hotkeys {
                if keyCode == hotkey.keyCode && relevantFlags == hotkey.modifiers {
                    print("\(hotkey.name) hotkey matched! Triggering callback...")
                    DispatchQueue.main.async {
                        hotkey.callback()
                    }
                    // Consume the event (don't pass it through)
                    return nil
                }
            }
        }

        // Pass through all other events
        return Unmanaged.passUnretained(event)
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func updateHotkeys(hotkeys: [HotkeyRegistration]) -> Bool {
        unregisterHotkeys()
        return registerHotkeys(hotkeys: hotkeys)
    }

    func isHotkeyRegistered() -> Bool {
        return eventTap != nil && !hotkeys.isEmpty
    }

    private func shortcutDisplayString(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var components: [String] = []

        if modifiers.contains(.maskCommand) {
            components.append("⌘")
        }
        if modifiers.contains(.maskShift) {
            components.append("⇧")
        }
        if modifiers.contains(.maskAlternate) {
            components.append("⌥")
        }
        if modifiers.contains(.maskControl) {
            components.append("⌃")
        }

        // Add the key name
        components.append(settings.keyNameForKeyCode(keyCode))

        return components.joined()
    }

    deinit {
        unregisterHotkeys()
    }
}
