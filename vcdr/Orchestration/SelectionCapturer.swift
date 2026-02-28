import ApplicationServices
import AppKit
import OSLog

struct SelectionCapturer: Sendable {

    // MARK: - Constants

    /// Apps that don't support kAXSelectedTextAttribute and need Cmd+C simulation instead.
    private static let cmdCFallbackBundleIDs: Set<String> = [
        "ru.keepcoder.Telegram",
        "org.alacritty",
    ]

    /// Virtual key code for C key
    private static let cKeyCode: UInt16 = 8
    /// Maximum time to wait for the clipboard to update after simulating Cmd+C
    private static let clipboardPollTimeout: Duration = .milliseconds(500)
    /// Interval between clipboard changeCount polls
    private static let clipboardPollInterval: Duration = .milliseconds(20)

    /// Reads the currently selected text in the frontmost app.
    ///
    /// For most apps, uses the Accessibility API (kAXSelectedTextAttribute), which avoids
    /// touching the clipboard. For apps in `cmdCFallbackBundleIDs` that don't support this
    /// attribute, simulates Cmd+C and reads the result from the clipboard.
    ///
    /// - Parameter bundleIdentifier: The bundle ID of the frontmost app, used to decide
    ///   whether to use the Cmd+C fallback path.
    /// - Returns: The selected text, or nil if nothing is selected.
    func capture(bundleIdentifier: String?) async -> String? {
        if let bundleID = bundleIdentifier, Self.cmdCFallbackBundleIDs.contains(bundleID) {
            return await captureViaCmdC()
        }
        return captureViaAccessibility()
    }

    // MARK: - Accessibility Path

    /// Reads selected text via kAXSelectedTextAttribute. Doesn't touch the clipboard
    /// and avoids the system alert sound ("bonk") when nothing is selected.
    private func captureViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success else {
            return nil
        }

        // AXUIElementCopyAttributeValue returns AnyObject; cast to AXUIElement
        let focusedElement = focusedElementRef as! AXUIElement

        var selectedTextRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        ) == .success else {
            return nil
        }

        guard let text = selectedTextRef as? String, !text.isEmpty else {
            return nil
        }

        Logger.actions.info("Captured highlighted text via AX (\(text.count) chars)")
        return text
    }

    // MARK: - Cmd+C Fallback Path

    /// Captures selected text by simulating Cmd+C for apps that don't support the
    /// Accessibility API's selected text attribute. Saves and restores the clipboard
    /// contents around the operation.
    private func captureViaCmdC() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousContents = pasteboard.string(forType: .string)

        simulateCmdC()

        let captured = await pollForClipboardChange(previousChangeCount: previousChangeCount)

        // Restore previous clipboard contents
        pasteboard.clearContents()
        if let previous = previousContents {
            pasteboard.setString(previous, forType: .string)
        }

        if let text = captured, !text.isEmpty {
            Logger.actions.info("Captured highlighted text via Cmd+C (\(text.count) chars)")
            return text
        }

        Logger.actions.info("Cmd+C fallback: no text captured (clipboard unchanged)")
        return nil
    }

    private func simulateCmdC() {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Polls `NSPasteboard.changeCount` until it differs from `previousChangeCount`
    /// or the timeout elapses. Returns the new clipboard string if the count changed.
    private func pollForClipboardChange(previousChangeCount: Int) async -> String? {
        let deadline = ContinuousClock.now + Self.clipboardPollTimeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount != previousChangeCount {
                return NSPasteboard.general.string(forType: .string)
            }
            try? await Task.sleep(for: Self.clipboardPollInterval)
        }
        return nil
    }
}
