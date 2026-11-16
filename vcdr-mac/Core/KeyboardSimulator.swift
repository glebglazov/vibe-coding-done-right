import ApplicationServices

enum KeyboardSimulator {
    /// Simulates Cmd+V via CGEvent posted to the HID event tap.
    static func simulateCmdV() {
        simulateCommandKeystroke(keyCode: KeyCodeMap.vKeyCode)
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
