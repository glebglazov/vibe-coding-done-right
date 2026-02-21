import AppKit
import OSLog

struct SelectionCapturer: Sendable {
    // MARK: - Constants

    /// Delay after simulating Cmd+C for the target app to update the clipboard
    private static let clipboardSettleDelay: Duration = .milliseconds(100)

    /// Virtual key code for the C key
    private static let cKeyCode: UInt16 = 8

    /// Attempts to capture the currently selected text in the frontmost app
    /// by simulating Cmd+C. Returns the selected text, or nil if nothing was selected.
    /// Restores the original clipboard string after capture.
    func capture() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousString = pasteboard.string(forType: .string)

        simulateCmdC()

        // Wait for the target app to process Cmd+C and update the clipboard
        try? await Task.sleep(for: Self.clipboardSettleDelay)

        guard pasteboard.changeCount != previousChangeCount else {
            // Clipboard didn't change — nothing was selected
            return nil
        }

        let capturedText = pasteboard.string(forType: .string)

        // Restore previous clipboard contents so the user's clipboard isn't affected
        pasteboard.clearContents()
        if let previousString {
            pasteboard.setString(previousString, forType: .string)
        }

        guard let capturedText, !capturedText.isEmpty else {
            return nil
        }

        Logger.actions.info("Captured highlighted text (\(capturedText.count) chars)")
        return capturedText
    }

    private func simulateCmdC() {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
