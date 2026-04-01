import AppKit
import ApplicationServices
import OSLog

struct PasteAction: PostTranscriptionAction {
    let name = "Paste"

    /// PID of the app to restore focus to before pasting.
    /// Using pid_t instead of NSRunningApplication to keep the action Sendable.
    private let targetAppPID: pid_t?
    private let saveResultToClipboard: Bool

    // MARK: - Constants

    private static let clipboardSettleDelay: Duration = .milliseconds(50)
    /// Maximum time to wait for the target app to gain focus before pasting
    private static let focusRestorationTimeout: Duration = .milliseconds(500)
    /// Polling interval when waiting for the target app to become active
    private static let focusPollingInterval: Duration = .milliseconds(20)

    init(targetAppPID: pid_t? = nil, saveResultToClipboard: Bool = false) {
        self.targetAppPID = targetAppPID
        self.saveResultToClipboard = saveResultToClipboard
    }

    func execute(text: String) async throws -> String? {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
        }

        if targetAppPID != nil {
            // Paste to Initial App: restore focus to the captured PID
            try await restoreFocus()
        }

        // Always use clipboard paste — AX insertion via kAXSelectedTextAttribute
        // is unreliable (e.g. HTML inputs in browsers accept the attribute set
        // but don't render the text). Clipboard + Cmd+V works universally.
        try await clipboardPaste(text: text)

        return nil
    }

    // MARK: - Focus Restoration

    private func restoreFocus() async throws {
        guard let pid = targetAppPID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            return
        }

        // Use NSWorkspace.openApplication to bring the target app to the front.
        // NSRunningApplication.activate() and NSApp.yieldActivation(to:) are unreliable
        // for activating a background app from a non-activating panel context.
        if let bundleURL = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            try? await NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        }

        // Poll until the target app is actually active, with timeout.
        // A fixed delay is unreliable — the app may be slow to activate
        // if the system is busy or another window holds focus.
        let deadline = ContinuousClock.now.advanced(by: Self.focusRestorationTimeout)
        while !app.isActive && ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.focusPollingInterval)
        }
        if !app.isActive {
            Logger.actions.warning("Target app (pid \(pid)) did not gain focus within timeout")
            throw ActionError.executionFailed("Could not activate \(app.localizedName ?? "target app") — focus restoration failed")
        }
    }

    // MARK: - Clipboard Paste

    private func clipboardPaste(text: String) async throws {
        // When not saving result to clipboard, use concealed write + restore
        let snapshot: ClipboardHelper.PasteboardSnapshot?
        if saveResultToClipboard {
            snapshot = nil
            ClipboardHelper.writeString(text)
            Logger.actions.info("Text copied to clipboard")
        } else {
            snapshot = ClipboardHelper.saveContents()
            ClipboardHelper.writeConcealedString(text)
            Logger.actions.info("Text written to clipboard (concealed, will restore)")
        }

        // Brief delay for clipboard to settle before simulating Cmd+V
        try await Task.sleep(for: Self.clipboardSettleDelay)

        KeyboardSimulator.simulateCmdV()
        Logger.actions.info("Paste simulated via Cmd+V")

        // Restore original clipboard contents after the target app has consumed the paste
        if let snapshot {
            try await Task.sleep(for: ClipboardHelper.clipboardRestorationDelay)
            ClipboardHelper.restoreContents(snapshot)
        }
    }
}
