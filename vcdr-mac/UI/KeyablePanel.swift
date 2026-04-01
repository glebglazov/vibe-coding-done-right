import AppKit

/// NSPanel subclass that accepts key events.
/// Used by ModeSwitcherPanel, CapturePanel, and RecordingIndicatorPanel.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Non-activating panels don't route key equivalents through the app's main menu,
    /// so standard editing shortcuts (Cmd+C/V/X/A/Z) won't reach the NSTextView.
    /// Forward them manually to the first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let characters = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector? = switch characters {
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "z" where event.modifierFlags.contains(.shift):
            NSSelectorFromString("redo:")
        case "z":
            #selector(UndoManager.undo)
        default: nil
        }

        if let selector {
            return NSApp.sendAction(selector, to: nil, from: self)
        }

        return super.performKeyEquivalent(with: event)
    }
}
