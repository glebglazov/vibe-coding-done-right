import AppKit

/// Utility for clipboard operations and synchronization
enum ClipboardHelper {
    /// Wait for clipboard changeCount to increase from the initial value
    /// - Parameters:
    ///   - initialChangeCount: The changeCount value before the clipboard operation
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if clipboard changed, false if timeout occurred
    static func waitForClipboardChange(from initialChangeCount: Int, timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            let currentChangeCount = NSPasteboard.general.changeCount

            if currentChangeCount != initialChangeCount {
                print("✅ ClipboardHelper: Clipboard changed after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ ClipboardHelper: Timeout waiting for clipboard change after \(timeout * 1000)ms")
        return false
    }

    /// Wait for clipboard content to be set (for direct writes)
    /// - Parameters:
    ///   - expectedText: The text that should be in the clipboard
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if clipboard contains expected text, false if timeout occurred
    static func waitForClipboardContent(_ expectedText: String, timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if let clipboardText = NSPasteboard.general.string(forType: .string),
               clipboardText == expectedText {
                print("✅ ClipboardHelper: Clipboard content verified after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ ClipboardHelper: Timeout waiting for clipboard content after \(timeout * 1000)ms")
        return false
    }
}
