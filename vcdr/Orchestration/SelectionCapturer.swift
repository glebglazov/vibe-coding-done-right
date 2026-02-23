import AppKit
import OSLog

struct SelectionCapturer: Sendable {
    /// Reads the currently selected text in the frontmost app via the Accessibility API
    /// (kAXSelectedTextAttribute). This avoids simulating Cmd+C which causes the system
    /// alert sound ("bonk") when nothing is selected, and doesn't touch the clipboard.
    /// Returns nil if no text is selected or if the focused app doesn't support the attribute.
    func capture() -> String? {
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

        Logger.actions.info("Captured highlighted text (\(text.count) chars)")
        return text
    }
}
