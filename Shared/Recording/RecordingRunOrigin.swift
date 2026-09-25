import Foundation

/// Where a Recording Run's record intent came from. The run's start fixes it,
/// and the trigger that stops the run never changes it: every delivery and
/// Capture decision reads this one value.
nonisolated enum RecordingRunOrigin: Equatable, Sendable {
    /// A control on the VCDR app surface.
    case app
    /// The keyboard extension, through a Keyboard Channel command or the
    /// Deep-Link Fallback.
    case keyboard
    /// The "Toggle Recording" App Intent: Shortcuts, Spotlight, the Action
    /// button, or an iPad hardware-keyboard shortcut.
    case shortcut

    /// A Shortcut run never reads or clears Captures, so it cannot consume
    /// the Captures a later keyboard run was meant to get.
    var usesKeyboardCaptures: Bool {
        switch self {
        case .app, .keyboard: true
        case .shortcut: false
        }
    }

    /// Only a keyboard run gets its terminal state as a Bundled Result or a
    /// terminal wire value. Every other run takes the Keyboard Channel back
    /// to idle.
    var deliversToKeyboard: Bool {
        switch self {
        case .keyboard: true
        case .app, .shortcut: false
        }
    }

    /// A Shortcut run has no surface of its own to show text on, so its final
    /// text goes to the clipboard and its outcome to Mic Presence.
    var deliversToClipboard: Bool {
        switch self {
        case .shortcut: true
        case .app, .keyboard: false
        }
    }

    /// The system stops an `AudioRecordingIntent` recording that has no Live
    /// Activity, so a Shortcut run keeps its card while VCDR is on screen.
    var keepsCardInForeground: Bool {
        switch self {
        case .shortcut: true
        case .app, .keyboard: false
        }
    }
}
