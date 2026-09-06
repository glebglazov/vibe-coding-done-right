import Foundation

/// The language a recording is in, as told to a Transcription Model that
/// accepts one. A decoder input rather than a preference: a hint that does not
/// match the speech makes Whisper translate into the hinted language instead of
/// transcribing it, fluently and with no error, which is why `detect` is a real
/// value meaning "send nothing" and why nothing in the app ever derives a hint
/// from the locale, the keyboard layout or a previous run (`docs/adr/0019`).
///
/// The languages are written out rather than read from a backend's own table:
/// this type compiles into both products and the keyboard extension, none of
/// which may import a transcription SDK. Each raw value is the code the model
/// is sent, so it outlives any rename of the case.
enum LanguageHint: String, Codable, Sendable, CaseIterable {
    /// Send no language, and let the model decide from the audio.
    case detect
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case czech = "cs"
    case swedish = "sv"
    case turkish = "tr"
    case arabic = "ar"
    case hindi = "hi"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"

    /// The code the model is sent, or nil for `detect` — where sending nothing
    /// is the whole point, so the absence has to survive all the way down to
    /// the decoding call.
    var languageCode: String? {
        self == .detect ? nil : rawValue
    }

    /// What the picker calls this hint.
    var displayName: String {
        switch self {
        case .detect: "Detect"
        case .english: "English"
        case .russian: "Russian"
        case .ukrainian: "Ukrainian"
        case .german: "German"
        case .french: "French"
        case .spanish: "Spanish"
        case .portuguese: "Portuguese"
        case .italian: "Italian"
        case .dutch: "Dutch"
        case .polish: "Polish"
        case .czech: "Czech"
        case .swedish: "Swedish"
        case .turkish: "Turkish"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }
}
