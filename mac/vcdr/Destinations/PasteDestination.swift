//
//  PasteDestination.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import AppKit
import ApplicationServices

class PasteDestination: TextDestination {
    let name = "Paste"
    let shouldRestoreFocus = true

    func send(text: String, onPrepareSend: (() async -> Void)? = nil) async throws {
        print("📋 PasteDestination: Copying text to clipboard...")

        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        print("✅ PasteDestination: Text copied to clipboard")

        // Check if we have accessibility permissions
        let hasPermissions = await hasAccessibilityPermissions()
        print("🔐 PasteDestination: Accessibility permissions check: \(hasPermissions)")

        guard hasPermissions else {
            print("❌ PasteDestination: No accessibility permissions for auto-paste")
            print("💡 Requesting accessibility permissions...")
            await requestAccessibilityPermissionsAsync()
            throw DestinationError.sendFailed("Accessibility permissions required for auto-paste. Please enable in System Settings > Privacy & Security > Accessibility")
        }

        print("✅ PasteDestination: Accessibility permissions available")

        // Wait for clipboard to be set with verification
        let clipboardReady = await ClipboardHelper.waitForClipboardContent(text)

        if !clipboardReady {
            print("⚠️ PasteDestination: Clipboard verification timeout, attempting paste anyway")
        }

        // Verify clipboard contents before pasting
        let clipboardText = pasteboard.string(forType: .string) ?? ""
        print("🔍 PasteDestination: Clipboard contents before paste: \"\(clipboardText)\"")

        // Call preparation callback (e.g., focus restoration) before pasting
        if let onPrepareSend = onPrepareSend {
            print("🎯 PasteDestination: Running preparation callback...")
            await onPrepareSend()
        }

        print("📤 PasteDestination: Simulating Cmd+V paste...")

        // Simulate Cmd+V to paste
        await simulatePaste()

        print("✅ PasteDestination: Text copied to clipboard and auto-pasted: \"\(clipboardText)\"")
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