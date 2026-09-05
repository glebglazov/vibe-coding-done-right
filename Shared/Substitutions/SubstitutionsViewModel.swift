import Foundation
import Observation

/// Drives the Substitutions settings tab. Owns the editable list shown in the
/// UI and persists every add / edit / delete through the `SubstitutionStore`.
///
/// The UI list (`drafts`) is the view's source of truth for *ordering* so a row
/// doesn't jump while the user is typing — the store re-sorts newest-edited
/// first on every `upsert`, which would otherwise reorder rows mid-edit. Edits
/// still flow straight to the store, so persistence and cross-device sync are
/// never deferred. `syncFromStore()` re-adopts the persisted snapshot when the
/// tab (re)appears, covering the launch race where the store finishes its
/// deferred bootstrap after this model was created.
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

    /// Re-adopts the persisted snapshot. Called when the tab appears so a list
    /// built before the store's deferred bootstrap finished still shows entries.
    func syncFromStore() {
        drafts = store.substitutions
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

        store.upsert(tidied)
        return .saved(tidied, clashes: clashes.clashes(for: tidied))
    }

    /// The Trigger Phrase Clashes across the persisted list, so a row can mark the
    /// phrases it loses and name the Replacement that beats each one.
    var clashes: TriggerPhraseClashes {
        TriggerPhraseClashes(among: store.substitutions)
    }

    func delete(_ substitution: Substitution) {
        drafts.removeAll { $0.id == substitution.id }
        store.delete(substitution)
    }
}
