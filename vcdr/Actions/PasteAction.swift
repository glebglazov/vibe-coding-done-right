import Foundation
import AppKit
import ApplicationServices
import OSLog

struct PasteAction: PostTranscriptionAction {
    let name = "Paste"

    // MARK: - Constants

    private static let clipboardSettleDelay: Duration = .milliseconds(50)

    func execute(text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
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
    }
}
