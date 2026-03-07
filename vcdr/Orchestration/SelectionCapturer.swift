import ApplicationServices
import AppKit
import OSLog

struct SelectionCapturer: Sendable {

    // MARK: - Constants

    /// Apps that skip AX entirely and go straight to Cmd+C simulation.
    private static let cmdCOnlyBundleIDs: Set<String> = [
        "ru.keepcoder.Telegram",
        "org.alacritty",
    ]

    /// Virtual key code for C key
    private static let cKeyCode: UInt16 = 8
    /// Maximum time to wait for the clipboard to update after simulating Cmd+C
    private static let clipboardPollTimeout: Duration = .milliseconds(300)
    /// Interval between clipboard changeCount polls
    private static let clipboardPollInterval: Duration = .milliseconds(20)

    /// Reads the currently selected text in the frontmost app.
    ///
    /// Tries the Accessibility API first (avoids touching the clipboard), then falls back
    /// to simulating Cmd+C for apps where AX doesn't expose selected text (e.g. WebKit views).
    /// Apps in `cmdCOnlyBundleIDs` skip AX entirely.
    ///
    /// - Parameter bundleIdentifier: The bundle ID of the frontmost app.
    /// - Returns: The selected text, or nil if nothing is selected.
    func capture(bundleIdentifier: String?) async -> String? {
        let skipAX = bundleIdentifier.map { Self.cmdCOnlyBundleIDs.contains($0) } ?? false
        if !skipAX, let text = captureViaAccessibility() {
            return text
        }
        return await captureViaCmdC()
    }

    // MARK: - Accessibility Path

    /// Reads selected text via kAXSelectedTextAttribute. Doesn't touch the clipboard
    /// and avoids the system alert sound ("bonk") when nothing is selected.
    private func captureViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success else {
            Logger.actions.warning("AX capture: failed to get focused element (error: \(focusedResult.rawValue))")
            return nil
        }

        // AXUIElementCopyAttributeValue returns AnyObject; cast to AXUIElement
        let focusedElement = focusedElementRef as! AXUIElement

        var roleRef: AnyObject?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRef) == .success {
            Logger.actions.info("AX capture: focused element role = \(roleRef as? String ?? "unknown")")
        }

        var selectedTextRef: AnyObject?
        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        )
        guard selectedResult == .success else {
            Logger.actions.warning("AX capture: failed to get selected text (error: \(selectedResult.rawValue))")
            return nil
        }

        guard let text = selectedTextRef as? String, !text.isEmpty else {
            Logger.actions.info("AX capture: selected text attribute returned empty or non-string")
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
