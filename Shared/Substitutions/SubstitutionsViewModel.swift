import Foundation
import Observation
import SwiftUI

/// Drives the Substitutions settings tab. Owns the editable list shown in the
/// UI and persists every edit and delete through the `SubstitutionStore`; an
/// add is a draft row only, reaching the store on its first commit that carries
/// a Replacement.
///
/// The UI list (`drafts`) is the view's source of truth for *ordering* so a row
/// doesn't jump while the user is typing — the store re-sorts newest-edited
/// first on every `upsert`, which would otherwise reorder rows mid-edit. Edits
/// still flow straight to the store, so persistence and cross-device sync are
/// never deferred. `syncFromStore()` takes in what the store holds whenever it
/// changes — the deferred bootstrap finishing, or a sync pass bringing in
/// another device's entries — without moving rows or undoing typing.
@MainActor
@Observable
final class SubstitutionsViewModel {

    private let store: any SubstitutionStore

    /// Editable, stably-ordered copy backing the list rows.
    var drafts: [Substitution]

    init(store: any SubstitutionStore) {
        self.store = store
        self.drafts = store.substitutions
    }

    /// What the store holds, for a view to watch so it can call
    /// `syncFromStore()` when it changes.
    var persisted: [Substitution] {
        store.substitutions
    }

    /// Takes in what the store holds, keeping the rows where they are. A row
    /// whose commit would change nothing keeps the draft, because that draft
    /// can hold what a commit tidies away while the user is still typing: a
    /// trailing space, or a blank Trigger row for the caret. A row with no
    /// Replacement is a draft the store never got, so it stays. Any other row
    /// the store no longer has was deleted, here or on another device. Entries
    /// new to this list go first, as the store orders them.
    func syncFromStore() {
        let stored = store.substitutions
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        let kept: [Substitution] = drafts.compactMap { draft in
            guard let persisted = storedByID[draft.id] else {
                return draft.replacement.isEmpty ? draft : nil
            }
            return draft.tidiedForCommit().wouldNotChange(persisted) ? draft : persisted
        }
        let keptIDs = Set(kept.map(\.id))
        drafts = stored.filter { !keptIDs.contains($0.id) } + kept
    }

    /// Appends a blank Substitution to the UI list and returns its id so the
    /// caller can push the detail view for editing. Nothing is written yet: the
    /// entry reaches disk on its first commit that carries a Replacement, so a
    /// substitution abandoned before anything is typed never syncs anywhere.
    /// New rows go to the end so existing rows keep their position.
    @discardableResult
    func add() -> UUID {
        let substitution = Substitution(triggerPhrases: [], replacement: "")
        drafts.append(substitution)
        return substitution.id
    }

    /// Applies the commit rules to an edited draft and persists the result,
    /// without reordering the UI list. Returns what the commit did so the editor
    /// can show the Trigger Phrase Clashes the entry lost.
    @discardableResult
    func commit(_ substitution: Substitution) -> SubstitutionCommit {
        let tidied = substitution.tidiedForCommit()

        guard !tidied.replacement.isEmpty else {
            // An entry that never reached disk has nothing to delete; one that did
            // is removed, so blanking a Replacement doesn't leave it on a peer.
            if store.substitutions.contains(where: { $0.id == tidied.id }) {
                delete(tidied)
            }
            return .discarded
        }

        // A commit carrying nothing new — an opened editor's blank Trigger
        // Phrase row, tidied away again — is answered from the persisted copy
        // rather than written over it.
        if let stored = store.substitutions.first(where: { $0.id == tidied.id }),
           tidied.wouldNotChange(stored) {
            return .saved(stored, clashes: clashes.clashes(for: stored))
        }

        store.upsert(tidied)
        return .saved(tidied, clashes: clashes.clashes(for: tidied))
    }

    /// The Trigger Phrase Clashes across the persisted list, so a row can mark the
    /// phrases it loses and name the Replacement that beats each one.
    var clashes: TriggerPhraseClashes {
        TriggerPhraseClashes(among: store.substitutions)
    }

    /// Edits one entry by identity rather than by index, for an editor screen
    /// open on it: a Replacement emptied while the screen is open evaporates the
    /// entry from the list, and typing into it again should bring it back the way
    /// a freshly drafted one arrives — not write to whatever row slid into its
    /// place. The stand-in for an absent entry is fixed rather than freshly
    /// stamped, so re-reading it never looks like an edit.
    func binding(for id: UUID) -> Binding<Substitution> {
        Binding(
            get: { [weak self] in
                self?.drafts.first { $0.id == id } ?? Self.evaporated(id)
            },
            set: { [weak self] edited in
                guard let self else { return }
                if let index = drafts.firstIndex(where: { $0.id == id }) {
                    drafts[index] = edited
                } else {
                    drafts.append(edited)
                }
            }
        )
    }

    private static func evaporated(_ id: UUID) -> Substitution {
        Substitution(id: id, triggerPhrases: [], replacement: "", lastUpdated: .distantPast)
    }

    func delete(_ substitution: Substitution) {
        drafts.removeAll { $0.id == substitution.id }
        store.delete(substitution)
    }
}
