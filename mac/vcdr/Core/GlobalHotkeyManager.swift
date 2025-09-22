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
    private var clipboardCallback: (() -> Void)?
    private var tmuxCallback: (() -> Void)?
    private let settings = AppSettings.shared

    func registerHotkeys(clipboardCallback: @escaping () -> Void, tmuxCallback: @escaping () -> Void) -> Bool {
        self.clipboardCallback = clipboardCallback
        self.tmuxCallback = tmuxCallback

        // Log current shortcut configuration
        print("🔧 Registering global hotkeys:")
        print("   Clipboard - \(settings.clipboardShortcutDisplayString)")
        print("   Tmux - \(settings.tmuxShortcutDisplayString)")

        // Check if at least one shortcut is set
        if !settings.isClipboardShortcutSet && !settings.isTmuxShortcutSet {
            print("⚠️ No shortcuts are set - skipping hotkey registration")
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
        if settings.isClipboardShortcutSet {
            print("   Listening for clipboard: \(settings.clipboardShortcutDisplayString)")
        }
        if settings.isTmuxShortcutSet {
            print("   Listening for tmux: \(settings.tmuxShortcutDisplayString)")
        }
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
            self.clipboardCallback = nil
            self.tmuxCallback = nil
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

            // Check clipboard shortcut (only if set)
            if settings.isClipboardShortcutSet &&
               keyCode == settings.clipboardShortcutKeyCode &&
               relevantFlags == settings.clipboardShortcutModifiers {
                print("Clipboard hotkey matched! Triggering clipboard callback...")
                DispatchQueue.main.async {
                    self.clipboardCallback?()
                }
                // Consume the event (don't pass it through)
                return nil
            }

            // Check tmux shortcut (only if set)
            if settings.isTmuxShortcutSet &&
               keyCode == settings.tmuxShortcutKeyCode &&
               relevantFlags == settings.tmuxShortcutModifiers {
                print("Tmux hotkey matched! Triggering tmux callback...")
                DispatchQueue.main.async {
                    self.tmuxCallback?()
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

    func updateHotkeys() -> Bool {
        if let clipboardCallback = self.clipboardCallback, let tmuxCallback = self.tmuxCallback {
            unregisterHotkeys()
            return registerHotkeys(clipboardCallback: clipboardCallback, tmuxCallback: tmuxCallback)
        }
        return false
    }

    func isHotkeyRegistered() -> Bool {
        // Consider registered if event tap is active and at least one shortcut is set
        let hasEventTap = eventTap != nil
        let hasAtLeastOneShortcut = settings.isClipboardShortcutSet || settings.isTmuxShortcutSet
        let hasCallbacks = clipboardCallback != nil && tmuxCallback != nil

        return hasEventTap && hasAtLeastOneShortcut && hasCallbacks
    }

    deinit {
        unregisterHotkeys()
    }
}
