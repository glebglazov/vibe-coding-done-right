import Foundation

/// A transient, run-adjacent status the recording screen's status row can
/// carry.
///
/// A closed set rather than a free-form string: the row is one line tall and
/// permanently reserved, so it sizes itself to the widest tenant once.
enum TransientStatus: Equatable, CaseIterable {
    case transcribing
    /// A run that finished with nothing to insert. Also the app's error
    /// message for an Empty Result, so the wording can't drift between the
    /// coordinator and the row.
    case noSpeechDetected

    var text: String {
        switch self {
        case .transcribing: Self.transcribingText
        case .noSpeechDetected: Self.noSpeechDetectedText
        }
    }

    static let transcribingText = "Transcribing…"
    static let noSpeechDetectedText = "No speech detected"
}
