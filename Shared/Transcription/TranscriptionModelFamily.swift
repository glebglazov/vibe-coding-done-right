import Foundation

/// A group of Transcription Models that share what they can be told. Every
/// Whisper is one family, Parakeet is its own: a Language Hint names the
/// language the speech is in and a vocabulary prompt names the speaker's own
/// proper nouns, so neither is a property of which size of a model decodes the
/// audio (`docs/adr/0020`).
///
/// This is the unit Transcription Model Settings, a Mode's patch and a
/// Capability all belong to. A family whose members disagree about a Capability
/// is not one family — that is the rule that decides whether a new model joins
/// one or starts another.
///
/// The raw value is the key those settings are stored under, and is written
/// down rather than derived from the case name, because it outlives any rename
/// of the case.
enum TranscriptionModelFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case parakeet = "parakeet"
    case whisper = "whisper"

    /// What a settings section and an inherited value's label call this family.
    /// Never a member's name: the value on screen is the family's, and naming a
    /// model would claim an owner that does not own it.
    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .whisper: "Whisper"
        }
    }
}

extension TranscriptionModelFamily {

    /// What an older build wrote this family's settings under: the raw value of
    /// the single model the family then held, back when a model keyed its
    /// settings by itself.
    private var keyBeforeFamilies: String {
        switch self {
        case .parakeet: TranscriptionModel.parakeetV3Key
        case .whisper: TranscriptionModel.whisperLargeV3Turbo.rawValue
        }
    }

    /// `stored`, read the way families key it. Anything an older build left
    /// under a model's own key becomes that model's family's, so a vocabulary
    /// prompt typed before this build is in force on the first read rather than
    /// waiting to be retyped. A family that already has an entry keeps it, and
    /// a key belonging to no family this build knows is carried through
    /// untouched.
    static func adoptingKeysBeforeFamilies<Value>(in stored: [String: Value]) -> [String: Value] {
        var adopted = stored
        for family in allCases where adopted[family.rawValue] == nil {
            guard let inherited = adopted.removeValue(forKey: family.keyBeforeFamilies) else { continue }
            adopted[family.rawValue] = inherited
        }
        return adopted
    }
}
