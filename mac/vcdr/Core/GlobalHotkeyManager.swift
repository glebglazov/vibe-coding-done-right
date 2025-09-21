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
    private var callback: (() -> Void)?
    private let settings = AppSettings.shared

    func registerHotkey(callback: @escaping () -> Void) -> Bool {
        self.callback = callback

        // Log current shortcut configuration
        print("🔧 Registering global hotkey:")
        print("   Key Code: \(settings.shortcutKeyCode)")
        print("   Modifiers: \(settings.shortcutModifiers.rawValue)")
        print("   Display: \(settings.shortcutDisplayString)")

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
        print("   Listening for: \(settings.shortcutDisplayString)")
        print("   Key Code: \(settings.shortcutKeyCode), Modifiers: \(settings.shortcutModifiers.rawValue)")
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
            self.callback = nil
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

            // Debug logging for all key events
            let requiredModifiers = settings.shortcutModifiers
            let relevantFlags = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

            // Log only when our target key is pressed
            if keyCode == settings.shortcutKeyCode {
                print("Target key pressed (\(keyCode)). Required modifiers: \(requiredModifiers.rawValue), Current modifiers: \(relevantFlags.rawValue)")
            }

            if keyCode == settings.shortcutKeyCode && relevantFlags == requiredModifiers {
                print("Hotkey matched! Triggering callback...")
                // This is our hotkey! Trigger the callback
                DispatchQueue.main.async {
                    self.callback?()
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
        if let callback = self.callback {
            unregisterHotkey()
            return registerHotkey(callback: callback)
        }
        return false
    }

    func isHotkeyRegistered() -> Bool {
        return eventTap != nil && callback != nil
    }

    deinit {
        unregisterHotkey()
    }
}