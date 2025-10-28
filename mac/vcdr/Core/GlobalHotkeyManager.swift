//
//  GlobalHotkeyManager.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import Carbon
import ApplicationServices

class GlobalHotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var capturingCallback: (() -> Void)?
    private let settings = AppSettings.shared

    func registerHotkey(callback: @escaping () -> Void) -> Bool {
        self.capturingCallback = callback

        // Log current shortcut configuration
        print("🔧 Registering global hotkey:")
        print("   Capturing - \(settings.capturingShortcutDisplayString)")

        // Check if shortcut is set
        if !settings.isCapturingShortcutSet {
            print("⚠️ No capturing shortcut is set - skipping hotkey registration")
            return true // Don't fail if no shortcut is set
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

        print("✅ Global hotkey registered successfully!")
        print("   Listening for: \(settings.capturingShortcutDisplayString)")
        return true
    }

    func unregisterHotkey() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)

            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }

            self.eventTap = nil
            self.capturingCallback = nil
            print("Global hotkey unregistered")
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

            // Check capturing shortcut (only if set)
            if settings.isCapturingShortcutSet &&
               keyCode == settings.capturingShortcutKeyCode &&
               relevantFlags == settings.capturingShortcutModifiers {
                print("Capturing hotkey matched! Triggering capturing callback...")
                DispatchQueue.main.async {
                    self.capturingCallback?()
                }
                // Consume the event (don't pass it through)
                return nil
            }
        }

        // Pass through all other events
        return Unmanaged.passUnretained(event)
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func updateHotkey() -> Bool {
        if let capturingCallback = self.capturingCallback {
            unregisterHotkey()
            return registerHotkey(callback: capturingCallback)
        }
        return false
    }

    func isHotkeyRegistered() -> Bool {
        let hasEventTap = eventTap != nil
        let hasShortcut = settings.isCapturingShortcutSet
        let hasCallback = capturingCallback != nil

        return hasEventTap && hasShortcut && hasCallback
    }

    deinit {
        unregisterHotkey()
    }
}
