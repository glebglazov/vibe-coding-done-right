import Foundation

/// Which Transcription Model a provider runs. One vocabulary for both products,
/// so a model is something the app can name rather than only something it can
/// print: settings, Library membership and a Mode's override all key by this,
/// where a display string would key by wording that is free to change.
///
/// The raw value is that key, and is written down rather than derived from the
/// case name, because it outlives any rename of the case.
enum TranscriptionModel: String, Sendable {
    case parakeetV3 = "parakeet-v3"

    /// What every readiness surface — menu bar, settings badge, recording pill —
    /// calls this model.
    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet Multilingual v3"
        }
    }
}
