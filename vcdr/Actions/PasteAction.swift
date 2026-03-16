import AppKit
import ApplicationServices
import OSLog

struct PasteAction: PostTranscriptionAction {
    let name = "Paste"

    /// PID of the app to restore focus to before pasting.
    /// Using pid_t instead of NSRunningApplication to keep the action Sendable.
    private let targetAppPID: pid_t?

    // MARK: - Constants

    private static let clipboardSettleDelay: Duration = .milliseconds(50)
    /// Maximum time to wait for the target app to gain focus before pasting
    private static let focusRestorationTimeout: Duration = .milliseconds(500)
    /// Polling interval when waiting for the target app to become active
    private static let focusPollingInterval: Duration = .milliseconds(20)
    /// Delay between word chunk insertions during AX streaming paste.
    /// Allows the target app's run loop to render each chunk.
    private static let streamingInterWordDelay: Duration = .milliseconds(10)

    init(targetAppPID: pid_t? = nil) {
        self.targetAppPID = targetAppPID
    }

    func execute(text: String) async throws -> String? {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
        }

        let app = try await restoreFocus()

        // Try AX streaming insertion first, fall back to clipboard paste
        if let app, try await insertViaAccessibility(text: text, targetApp: app) {
            Logger.actions.info("Paste completed via AX streaming insertion")
        } else {
            try await clipboardPaste(text: text)
        }

        return nil
    }

    // MARK: - Focus Restoration

    private func restoreFocus() async throws -> NSRunningApplication? {
        guard let pid = targetAppPID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            return nil
        }

        app.activate()
        // Poll until the target app is actually active, with timeout.
        // A fixed delay is unreliable — the app may be slow to activate
        // if the system is busy or another window holds focus.
        let deadline = ContinuousClock.now.advanced(by: Self.focusRestorationTimeout)
        while !app.isActive && ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.focusPollingInterval)
        }
        if !app.isActive {
            Logger.actions.warning("Target app (pid \(pid)) did not gain focus within timeout, attempting paste anyway")
        }
        return app
    }

    // MARK: - AX Streaming Insertion

    /// Inserts text word-by-word at the cursor via the Accessibility API.
    /// Returns `true` if AX insertion was used (even partially), `false` if the
    /// focused element doesn't support it — caller should fall back to clipboard.
    private func insertViaAccessibility(text: String, targetApp: NSRunningApplication) async throws -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return false
        }

        // CFTypeRef from kAXFocusedUIElementAttribute is always an AXUIElement
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)

        // Verify the focused element supports text insertion
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        // Split into word + trailing whitespace chunks to stream progressively
        let chunks = text.matches(of: #/\S+\s*/#).map { String($0.output) }
        guard !chunks.isEmpty else { return false }

        for chunk in chunks {
            // Stop if the user switched away from the target app
            guard targetApp.isActive else {
                Logger.actions.info("Target app lost focus during streaming paste, stopped early")
                break
            }

            let result = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                chunk as CFString
            )
            guard result == .success else {
                Logger.actions.warning("AX text insertion failed with error \(result.rawValue)")
                // Partial text may already be inserted — don't fall back to clipboard
                return true
            }

            try await Task.sleep(for: Self.streamingInterWordDelay)
        }

        return true
    }

    // MARK: - Clipboard Paste Fallback

    private func clipboardPaste(text: String) async throws {
        ClipboardHelper.writeString(text)
        Logger.actions.info("Text copied to clipboard")

        // Brief delay for clipboard to settle before simulating Cmd+V
        try await Task.sleep(for: Self.clipboardSettleDelay)

        KeyboardSimulator.simulateCmdV()
        Logger.actions.info("Paste simulated via Cmd+V")
    }
}
