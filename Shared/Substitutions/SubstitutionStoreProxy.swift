import Foundation
import Observation

/// Queues Substitution edits until a real store is assigned, then flushes them.
/// Lets `AppDependencies` hand out a stable store reference at launch while the
/// real (possibly iCloud-backed) store is resolved off-main.
///
/// Once the real store is assigned, `substitutions` reads straight from it, so
/// an entry a sync pass brings in reaches the screens and the text-processing
/// pipeline the moment the store has it, and redraws whatever read it.
///
/// Mirrors `HistoryStoreProxy` — the same shell-first bootstrap pattern.
@MainActor
@Observable
final class SubstitutionStoreProxy: SubstitutionStore {

    private enum PendingOp {
        case upsert(Substitution)
        case delete(Substitution)
    }

    private var realStore: (any SubstitutionStore)?
    private var pendingOps: [PendingOp] = []

    /// What the edits made before the real store was assigned add up to, shown
    /// until it is.
    private var pendingSubstitutions: [Substitution] = []

    var substitutions: [Substitution] {
        realStore?.substitutions ?? pendingSubstitutions
    }

    /// Installs the resolved store and replays any edits made before it was ready.
    func setRealStore(_ store: any SubstitutionStore) {
        for op in pendingOps {
            switch op {
            case .upsert(let substitution): store.upsert(substitution)
            case .delete(let substitution): store.delete(substitution)
            }
        }
        pendingOps.removeAll()
        pendingSubstitutions.removeAll()

        realStore = store
    }

    func upsert(_ substitution: Substitution) {
        if let real = realStore {
            real.upsert(substitution)
        } else {
            pendingOps.append(.upsert(substitution))
            pendingSubstitutions.removeAll { $0.id == substitution.id }
            pendingSubstitutions.insert(substitution, at: 0)
        }
    }

    func delete(_ substitution: Substitution) {
        if let real = realStore {
            real.delete(substitution)
        } else {
            pendingOps.append(.delete(substitution))
            pendingSubstitutions.removeAll { $0.id == substitution.id }
        }
    }

    func reload() {
        realStore?.reload()
    }
}
