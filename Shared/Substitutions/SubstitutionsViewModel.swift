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

    /// Appends a blank Substitution, persists it, and returns its id so the
    /// caller can push the detail view for editing. New rows go to the end so
    /// existing rows keep their position.
    @discardableResult
    func add() -> UUID {
        let substitution = Substitution(triggerPhrase: "", replacement: "")
        drafts.append(substitution)
        store.upsert(substitution)
        return substitution.id
    }

    /// Persists an in-place edit to an existing draft without reordering the UI list.
    func persist(_ substitution: Substitution) {
        store.upsert(substitution)
    }

    func delete(_ substitution: Substitution) {
        drafts.removeAll { $0.id == substitution.id }
        store.delete(substitution)
    }
}
