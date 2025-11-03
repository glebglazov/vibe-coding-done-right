//
//  CopyDestination.swift
//  vcdr
//
//  Simple clipboard copy without auto-paste
//

import Foundation
import AppKit

class CopyDestination: TextDestination {
    let name = "Copy"
    let shouldRestoreFocus = true

    func send(text: String, onPrepareSend: (() async -> Void)? = nil) async throws {
        print("📋 CopyDestination: Copying text to clipboard...")

        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        print("✅ CopyDestination: Text copied to clipboard: \"\(text.prefix(50))...\"")

        // Call preparation callback (e.g., focus restoration)
        if let onPrepareSend = onPrepareSend {
            print("🎯 CopyDestination: Running preparation callback...")
            await onPrepareSend()
        }
    }

    func isAvailable() async -> Bool {
        return true // Always available since no special permissions needed
    }
}
