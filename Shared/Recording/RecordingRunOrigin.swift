import Foundation

nonisolated enum RecordingRunOrigin: Equatable, Sendable {
    case app
    case keyboard
    case shortcut

    var usesKeyboardCaptures: Bool {
        switch self {
        case .app, .keyboard: true
        case .shortcut: false
        }
    }

    var deliversToKeyboard: Bool {
        switch self {
        case .keyboard: true
        case .app, .shortcut: false
        }
    }

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
