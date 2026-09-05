import Foundation

/// One entry in the iCloud-synced shared list that swaps spoken text for fixed
/// text in the raw transcript. A Substitution holds one Replacement
/// (`replacement`) and any number of Trigger Phrases (`triggerPhrases`) that
/// produce it, and applies on both macOS and iOS before any other text
/// processing. See the Shared glossary (CONTEXT) for the Substitution /
/// Trigger Phrase / Replacement language.
struct Substitution: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity used for per-entry iCloud storage and SwiftUI updates.
    let id: UUID
    /// Spoken texts that activate this Substitution when any one of them appears
    /// in the transcript — each matched case-insensitively, on whole-word
    /// boundaries. An unordered set: no phrase takes precedence over another,
    /// and it is an array only because JSON has no set.
    var triggerPhrases: [String]
    /// Fixed text swapped in for any matched Trigger Phrase. Injected verbatim;
    /// never re-scanned for further Trigger Phrases.
    var replacement: String
    /// Last edit timestamp, used by the store for last-writer-wins conflict
    /// resolution across devices.
    var lastUpdated: Date
    /// When `false` the matcher skips this entry entirely.
    var isEnabled: Bool
    /// Schema generation of the file this entry came from. Written so a later
    /// field can tell an old file from a new one without guessing from keys.
    var schemaVersion: Int
    /// Top-level JSON keys written by a newer schema that this binary doesn't
    /// know about. Preserved verbatim so old readers round-trip new data without
    /// clobbering unknown fields.
    var extras: [String: AnyJSON]

    /// The phrase that goes in the singular `triggerPhrase` key for builds that
    /// predate the array (see ADR-0008). A landing pad written on encode, not a
    /// field an editor works through: both editors edit `triggerPhrases`.
    var triggerPhrase: String {
        get { triggerPhrases.first ?? "" }
        set {
            if triggerPhrases.isEmpty {
                triggerPhrases = [newValue]
            } else {
                triggerPhrases[0] = newValue
            }
        }
    }

    init(
        id: UUID = UUID(),
        triggerPhrases: [String],
        replacement: String,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true,
        schemaVersion: Int = Substitution.currentSchemaVersion,
        extras: [String: AnyJSON] = [:]
    ) {
        self.id = id
        self.triggerPhrases = triggerPhrases
        self.replacement = replacement
        self.lastUpdated = lastUpdated
        self.isEnabled = isEnabled
        self.schemaVersion = schemaVersion
        self.extras = extras
    }

    init(
        id: UUID = UUID(),
        triggerPhrase: String,
        replacement: String,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.init(
            id: id,
            triggerPhrases: [triggerPhrase],
            replacement: replacement,
            lastUpdated: lastUpdated,
            isEnabled: isEnabled
        )
    }

    static let currentSchemaVersion = 1

    // MARK: - Codable

    /// Known top-level keys this binary recognizes. Anything else lands in `extras`.
    private static let knownKeys: Set<String> = [
        "id", "triggerPhrases", "replacement", "lastUpdated", "isEnabled", "schemaVersion",
        // The pre-array key, still written for older readers:
        "triggerPhrase",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        // The array when the writer knew about it, otherwise the one phrase the
        // older writer left in the singular key. Only the second path can throw,
        // which is the pre-array file shape and always has the key.
        let triggerPhrases: [String]
        if let phrases = try container.decodeIfPresent([String].self, forKey: AnyCodingKey("triggerPhrases")) {
            triggerPhrases = phrases
        } else {
            triggerPhrases = [try container.decode(String.self, forKey: AnyCodingKey("triggerPhrase"))]
        }

        var extras: [String: AnyJSON] = [:]
        for key in container.allKeys where !Substitution.knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(AnyJSON.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }

        self.init(
            id: try container.decode(UUID.self, forKey: AnyCodingKey("id")),
            triggerPhrases: triggerPhrases,
            replacement: try container.decode(String.self, forKey: AnyCodingKey("replacement")),
            lastUpdated: try container.decode(Date.self, forKey: AnyCodingKey("lastUpdated")),
            isEnabled: try container.decode(Bool.self, forKey: AnyCodingKey("isEnabled")),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion"))
                ?? Substitution.currentSchemaVersion,
            extras: extras
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(triggerPhrases, forKey: AnyCodingKey("triggerPhrases"))
        // A landing pad, not a field: a build that predates the array requires
        // this key and would otherwise drop the whole entry (ADR-0008).
        try container.encode(triggerPhrase, forKey: AnyCodingKey("triggerPhrase"))
        try container.encode(replacement, forKey: AnyCodingKey("replacement"))
        try container.encode(lastUpdated, forKey: AnyCodingKey("lastUpdated"))
        try container.encode(isEnabled, forKey: AnyCodingKey("isEnabled"))
        try container.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))

        // Re-emit preserved unknown fields verbatim. If a caller explicitly
        // stored a value under a known key, the known-key write above wins.
        for (key, value) in extras where !Substitution.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

// MARK: - Dynamic CodingKey

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
