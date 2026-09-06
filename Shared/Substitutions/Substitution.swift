import Foundation

/// One entry in the shared list that swaps spoken text for fixed text in the
/// raw transcript. A Substitution holds one Replacement (`replacement`) and any
/// number of Trigger Phrases (`phrases`) that produce it, and applies on both
/// macOS and iOS before any other text processing. See the Shared glossary
/// (CONTEXT) for the Substitution / Trigger Phrase / Replacement language.
struct Substitution: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity used for per-entry Record Files and SwiftUI updates.
    let id: UUID
    /// Every Trigger Phrase this entry has carried, the removed ones included:
    /// a removal is kept so it can beat a peer's stale addition when two
    /// entries converge. `livePhrases` is the set the app acts on.
    var phrases: [TriggerPhrase]
    /// Fixed text swapped in for any matched Trigger Phrase. Injected verbatim;
    /// never re-scanned for further Trigger Phrases.
    var replacement: String
    /// When this entry was first made, on whichever device made it. It never
    /// moves, which is what lets two devices agree on the older of two entries
    /// holding one Replacement without asking each other (ADR-0011). An entry
    /// from a build that wrote no such field takes its Merge Stamp — when that
    /// build last wrote it, and the closest that file comes to saying.
    let createdAt: Date
    /// Merge Stamp: the clock two copies of this entry are settled against,
    /// used by the store for last-writer-wins resolution across devices.
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

    /// The Trigger Phrases still on the entry — the rows the editors show and
    /// the phrases the matcher scans.
    var livePhrases: [TriggerPhrase] {
        phrases.filter(\.isLive)
    }

    /// The live Trigger Phrases as plain text. Also the `triggerPhrases` key of
    /// the encoded form, kept for builds that read the array but not the stamps
    /// (ADR-0008).
    var triggerPhrases: [String] {
        livePhrases.map(\.text)
    }

    /// The phrase that goes in the singular `triggerPhrase` key for builds that
    /// predate the array (see ADR-0008). A landing pad written on encode, not a
    /// field an editor works through.
    var triggerPhrase: String {
        triggerPhrases.first ?? ""
    }

    // MARK: - Editing phrases

    /// One phrase's text, addressed by its identity so a row keeps its stamps
    /// while it is retyped. What both editors bind a Trigger field to.
    subscript(phrase id: UUID) -> String {
        get { phrases.first { $0.id == id }?.text ?? "" }
        set {
            guard let index = phrases.firstIndex(where: { $0.id == id }) else { return }
            phrases[index].text = newValue
        }
    }

    /// Adds an empty phrase for the user to type into. It reaches no peer until
    /// a commit carries text, because a commit drops blank phrases.
    mutating func addPhrase() {
        phrases.append(TriggerPhrase(text: "", addedAt: Date()))
    }

    /// Forgets the phrases still holding no text. They leave no removal behind
    /// because a blank phrase never reached disk for a peer to be showing: it is
    /// the row an opened editor puts the caret in, dropped again when the editor
    /// closes with nothing typed into it.
    mutating func dropBlankPhrases() {
        phrases.removeAll { $0.isLive && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Takes a phrase off the entry, keeping the record so the removal travels
    /// to the devices that still show it.
    mutating func removePhrase(_ id: UUID, at now: Date = Date()) {
        guard let index = phrases.firstIndex(where: { $0.id == id }) else { return }
        phrases[index].remove(at: now)
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        phrases: [TriggerPhrase],
        replacement: String,
        createdAt: Date? = nil,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true,
        schemaVersion: Int = Substitution.currentSchemaVersion,
        extras: [String: AnyJSON] = [:]
    ) {
        self.id = id
        self.phrases = phrases
        self.replacement = replacement
        self.createdAt = createdAt ?? lastUpdated
        self.lastUpdated = lastUpdated
        self.isEnabled = isEnabled
        self.schemaVersion = schemaVersion
        self.extras = extras
    }

    /// A Substitution from plain phrases, each stamped as added when the entry
    /// was — how an entry arrives from a build that wrote no stamps, and the
    /// shape the editors and tests build one in.
    init(
        id: UUID = UUID(),
        triggerPhrases: [String],
        replacement: String,
        createdAt: Date? = nil,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.init(
            id: id,
            phrases: triggerPhrases.map { TriggerPhrase(text: $0, addedAt: lastUpdated) },
            replacement: replacement,
            createdAt: createdAt,
            lastUpdated: lastUpdated,
            isEnabled: isEnabled
        )
    }

    init(
        id: UUID = UUID(),
        triggerPhrase: String,
        replacement: String,
        createdAt: Date? = nil,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.init(
            id: id,
            triggerPhrases: [triggerPhrase],
            replacement: replacement,
            createdAt: createdAt,
            lastUpdated: lastUpdated,
            isEnabled: isEnabled
        )
    }

    static let currentSchemaVersion = 1

    // MARK: - Codable

    /// Known top-level keys this binary recognizes. Anything else lands in `extras`.
    private static let knownKeys: Set<String> = [
        "id", "phrases", "replacement", "createdAt", "lastUpdated", "isEnabled", "schemaVersion",
        // The pre-stamp keys, still written for older readers:
        "triggerPhrases", "triggerPhrase",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let lastUpdated = try container.decode(Date.self, forKey: AnyCodingKey("lastUpdated"))

        // The stamped phrases when the writer knew about them; otherwise the
        // plain ones, added as far as this device can tell when the entry was
        // last written. Only the last path can throw, which is the pre-array
        // file shape and always has the singular key.
        let phrases: [TriggerPhrase]
        if let stamped = try container.decodeIfPresent([TriggerPhrase].self, forKey: AnyCodingKey("phrases")) {
            phrases = stamped
        } else if let texts = try container.decodeIfPresent([String].self, forKey: AnyCodingKey("triggerPhrases")) {
            phrases = texts.map { TriggerPhrase(text: $0, addedAt: lastUpdated) }
        } else {
            let text = try container.decode(String.self, forKey: AnyCodingKey("triggerPhrase"))
            phrases = [TriggerPhrase(text: text, addedAt: lastUpdated)]
        }

        var extras: [String: AnyJSON] = [:]
        for key in container.allKeys where !Substitution.knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(AnyJSON.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }

        self.init(
            id: try container.decode(UUID.self, forKey: AnyCodingKey("id")),
            phrases: phrases,
            replacement: try container.decode(String.self, forKey: AnyCodingKey("replacement")),
            createdAt: try container.decodeIfPresent(Date.self, forKey: AnyCodingKey("createdAt")),
            lastUpdated: lastUpdated,
            isEnabled: try container.decode(Bool.self, forKey: AnyCodingKey("isEnabled")),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion"))
                ?? Substitution.currentSchemaVersion,
            extras: extras
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(phrases, forKey: AnyCodingKey("phrases"))
        // Landing pads, not fields: a build that predates the stamps reads the
        // array, one that predates the array requires the singular key, and
        // either would otherwise drop the whole entry (ADR-0008).
        try container.encode(triggerPhrases, forKey: AnyCodingKey("triggerPhrases"))
        try container.encode(triggerPhrase, forKey: AnyCodingKey("triggerPhrase"))
        try container.encode(replacement, forKey: AnyCodingKey("replacement"))
        try container.encode(createdAt, forKey: AnyCodingKey("createdAt"))
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
