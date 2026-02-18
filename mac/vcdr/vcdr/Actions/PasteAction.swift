import Foundation
import AppKit
import ApplicationServices
import OSLog

struct PasteAction: PostTranscriptionAction {
    let name = "Paste"

    func execute(text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
        }

        let textToPaste = prefixIfNeeded(text)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToPaste, forType: .string)
        Logger.actions.info("Text copied to clipboard")

        // Brief delay for clipboard to settle
        try await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        Logger.actions.info("Paste simulated via Cmd+V")
    }

    private func prefixIfNeeded(_ text: String) -> String {
        guard let focusedElement = getFocusedTextElement() else {
            // Can't read focused element (e.g. terminal apps) — assume there's existing text
            Logger.actions.info("No accessible text field, prepending separator by default")
            return ". " + text
        }

        guard let existingText = getTextValue(focusedElement),
              !existingText.isEmpty else {
            return text
        }

        Logger.actions.info("Input has existing text, prepending separator")
        return ". " + text
    }

    private func getFocusedTextElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focused = focusedRef else { return nil }
        return (focused as! AXUIElement)
    }

    private func getTextValue(_ element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard result == .success, let value = valueRef as? String else { return nil }
        return value
    }
}
