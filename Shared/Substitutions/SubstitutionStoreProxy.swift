import Foundation
import Observation

/// Queues Substitution edits until a real store is assigned, then flushes them.
/// Mirrors the real store's observable `substitutions` so views and the
/// text-processing pipeline reading through the proxy get proper @Observation
/// invalidation. Lets `AppDependencies` hand out a stable store reference at
/// launch while the real (possibly iCloud-backed) store is resolved off-main.
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

    private(set) var substitutions: [Substitution] = []

    /// Installs the resolved store, replays any edits made before it was ready,
    /// then adopts its snapshot.
    func setRealStore(_ store: any SubstitutionStore) {
        realStore = store

        for op in pendingOps {
            switch op {
            case .upsert(let substitution): store.upsert(substitution)
            case .delete(let substitution): store.delete(substitution)
            }
        }
        pendingOps.removeAll()

        syncFromRealStore()
    }

    func upsert(_ substitution: Substitution) {
        if let real = realStore {
            real.upsert(substitution)
            syncFromRealStore()
        } else {
            pendingOps.append(.upsert(substitution))
            // Optimistic in-memory update so the UI reflects the edit immediately.
            substitutions.removeAll { $0.id == substitution.id }
            substitutions.insert(substitution, at: 0)
        }
    }

    func delete(_ substitution: Substitution) {
        if let real = realStore {
            real.delete(substitution)
            syncFromRealStore()
        } else {
            pendingOps.append(.delete(substitution))
            substitutions.removeAll { $0.id == substitution.id }
        }
    }

    func reload() {
        realStore?.reload()
        syncFromRealStore()
    }

    private func syncFromRealStore() {
        guard let realStore else { return }
        substitutions = realStore.substitutions
    }
}
