import Foundation
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
    /// Delay for the target app to gain focus before simulating Cmd+V
    private static let focusRestorationDelay: Duration = .milliseconds(100)

    init(targetAppPID: pid_t? = nil) {
        self.targetAppPID = targetAppPID
    }

    func execute(text: String) async throws -> String? {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
        }

        // Restore focus to the app that was active before recording started
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            // Brief delay for the target app to gain focus before simulating Cmd+V
            try await Task.sleep(for: Self.focusRestorationDelay)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Logger.actions.info("Text copied to clipboard")

        // Brief delay for clipboard to settle before simulating Cmd+V
        try await Task.sleep(for: Self.clipboardSettleDelay)

        // Simulate Cmd+V
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        Logger.actions.info("Paste simulated via Cmd+V")
        return nil
    }
}
