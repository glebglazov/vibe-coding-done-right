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

    /// A Shortcut run has no VCDR screen to show its result, so the card shows it.
    var showsOutcomeOnCard: Bool {
        switch self {
        case .shortcut: true
        case .app, .keyboard: false
        }
    }

    /// A Shortcut run gives its text to the Shortcut through Stop Recording. A
    /// stop from the card would end it with the text only in history.
    var stopsFromCard: Bool {
        switch self {
        case .shortcut: false
        case .app, .keyboard: true
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
