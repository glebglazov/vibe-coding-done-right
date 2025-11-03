//
//  PreviewDestination.swift
//  vcdr
//
//  Created by Claude Code
//

import Foundation

class PreviewDestination: TextDestination {
    let name = "Preview"
    let shouldRestoreFocus = false

    // Callback to show preview window with text
    var onShowPreview: ((String) -> Void)?

    func send(text: String, onPrepareSend: (() async -> Void)? = nil) async throws {
        print("👁️ PreviewDestination: Showing preview window...")

        // Call preparation callback (e.g., focus restoration)
        if let onPrepareSend = onPrepareSend {
            print("🎯 PreviewDestination: Running preparation callback...")
            await onPrepareSend()
        }

        // Show preview window
        await MainActor.run {
            onShowPreview?(text)
        }

        print("✅ PreviewDestination: Preview window shown")
    }

    func isAvailable() async -> Bool {
        return true // Always available
    }
}
