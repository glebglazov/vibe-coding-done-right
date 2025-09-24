//
//  ClipboardDestination.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import AppKit
import ApplicationServices

class ClipboardDestination: TextDestination {
    let name = "Clipboard (Auto-paste)"

    func send(text: String, onPrepareSend: (() async -> Void)? = nil) async throws {
        print("📋 ClipboardDestination: Copying text to clipboard...")

        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        print("✅ ClipboardDestination: Text copied to clipboard")

        // Check if we have accessibility permissions
        let hasPermissions = await hasAccessibilityPermissions()
        print("🔐 ClipboardDestination: Accessibility permissions check: \(hasPermissions)")

        guard hasPermissions else {
            print("❌ ClipboardDestination: No accessibility permissions for auto-paste")
            print("💡 Requesting accessibility permissions...")
            await requestAccessibilityPermissionsAsync()
            throw DestinationError.sendFailed("Accessibility permissions required for auto-paste. Please enable in System Settings > Privacy & Security > Accessibility")
        }

        print("✅ ClipboardDestination: Accessibility permissions available")

        // Small delay to ensure clipboard is set
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Verify clipboard contents before pasting
        let clipboardText = pasteboard.string(forType: .string) ?? ""
        print("🔍 ClipboardDestination: Clipboard contents before paste: \"\(clipboardText)\"")

        // Call preparation callback (e.g., focus restoration) before pasting
        if let onPrepareSend = onPrepareSend {
            print("🎯 ClipboardDestination: Running preparation callback...")
            await onPrepareSend()
        }

        print("📤 ClipboardDestination: Simulating Cmd+V paste...")

        // Simulate Cmd+V to paste
        await simulatePaste()

        print("✅ ClipboardDestination: Text copied to clipboard and auto-pasted: \"\(clipboardText)\"")
    }

    func isAvailable() async -> Bool {
        return await hasAccessibilityPermissions()
    }

    private func hasAccessibilityPermissions() async -> Bool {
        return AXIsProcessTrusted()
    }

    private func simulatePaste() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Create the key events for Cmd+V
                let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) // 'V' key
                let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)

                // Set the Command modifier
                keyDownEvent?.flags = .maskCommand
                keyUpEvent?.flags = .maskCommand

                // Post the events
                keyDownEvent?.post(tap: .cghidEventTap)
                keyUpEvent?.post(tap: .cghidEventTap)

                continuation.resume()
            }
        }
    }

    func requestAccessibilityPermissions() {
        // Prompt user to grant accessibility permissions
        let trusted = AXIsProcessTrusted()
        if !trusted {
            // This will show the system dialog asking for accessibility permissions
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func requestAccessibilityPermissionsAsync() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.requestAccessibilityPermissions()
                continuation.resume()
            }
        }
    }
}