//
//  WindowHelper.swift
//  vcdr
//
//  Created by Gleb Glazov on 18/12/25.
//

import AppKit

/// Utility for window management operations
enum WindowHelper {
    /// Wait for a window with the specified title to appear in NSApp.windows
    /// - Parameters:
    ///   - title: The window title to search for
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: The window if found, nil if timeout occurred
    static func waitForWindow(titled title: String, timeout: TimeInterval = 0.5) async -> NSWindow? {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if let window = NSApp.windows.first(where: { $0.title == title }) {
                print("✅ WindowHelper: Found window '\(title)' after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return window
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ WindowHelper: Timeout waiting for window '\(title)' after \(timeout * 1000)ms")
        return nil
    }
}
