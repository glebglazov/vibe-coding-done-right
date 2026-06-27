import Foundation

/// One entry in the iCloud-synced shared list that swaps a spoken phrase for
/// fixed text in the raw transcript. A Substitution pairs a Trigger Phrase
/// (`triggerPhrase`) with a Replacement (`replacement`) and applies on both
/// macOS and iOS before any other text processing. See the Shared glossary
/// (CONTEXT) for the Substitution / Trigger Phrase / Replacement language.
struct Substitution: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity used for per-entry iCloud storage and SwiftUI updates.
    let id: UUID
    /// Spoken text that activates this Substitution when it appears in the
    /// transcript — matched case-insensitively, on whole-word boundaries.
    var triggerPhrase: String
    /// Fixed text swapped in for the Trigger Phrase. Injected verbatim; never
    /// re-scanned for further Trigger Phrases.
    var replacement: String
    /// Last edit timestamp, used by the store for last-writer-wins conflict
    /// resolution across devices.
    var lastUpdated: Date
    /// When `false` the matcher skips this entry entirely.
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        triggerPhrase: String,
        replacement: String,
        lastUpdated: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.triggerPhrase = triggerPhrase
        self.replacement = replacement
        self.lastUpdated = lastUpdated
        self.isEnabled = isEnabled
    }
}
