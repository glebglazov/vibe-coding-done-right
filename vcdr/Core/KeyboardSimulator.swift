import ApplicationServices

enum KeyboardSimulator {
    // MARK: - Constants

    /// Virtual key code for C key
    private static let cKeyCode: UInt16 = 8
    /// Virtual key code for V key
    private static let vKeyCode: UInt16 = 9

    /// Simulates Cmd+C via CGEvent posted to the HID event tap.
    static func simulateCmdC() {
        simulateCommandKeystroke(keyCode: cKeyCode)
    }

    /// Simulates Cmd+V via CGEvent posted to the HID event tap.
    static func simulateCmdV() {
        simulateCommandKeystroke(keyCode: vKeyCode)
    }

    private static func simulateCommandKeystroke(keyCode: UInt16) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
