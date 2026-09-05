import Foundation
import OSLog

/// iCloud Drive-backed Substitution store. Composes over `FileSubstitutionStore`,
/// pointing it at the ubiquity container's `Documents/VCDR` directory.
///
/// Background sync is handled by the OS iCloud daemon. This store layers on:
///   * `NSMetadataQuery` watcher — picks up remote changes, kicks off
///     placeholder downloads, and reloads the list.
///   * LWW conflict resolution — when concurrent edits produce `NSFileVersion`
///     siblings on the same entry, the one with the latest
///     `Substitution.lastUpdated` wins.
///   * Account-state observation — surfaces `.paused` when the user signs out
///     of iCloud mid-session.
///
/// Construction uses a Sendable `Snapshot` loaded off the main actor — when
/// the ubiquity container is unavailable, callers fall back to a local-only
/// `FileSubstitutionStore` before ever reaching this type.
///
/// Unlike history, the Substitutions list is small, so remote
/// changes are applied immediately on every update rather than gated behind a
/// "pending updates" prompt.
@MainActor
@Observable
final class UbiquitySubstitutionStore: SubstitutionStore {

    nonisolated static let containerIdentifier = "iCloud.glebglazov.vcdr"

    /// Resolves the root of the ubiquity container's `Documents/VCDR` folder, or
    /// nil if iCloud is unavailable to the process right now.
    ///
    /// `Documents/` is required for the folder to appear in Files.app and
    /// Finder's iCloud Drive view — a useful debug escape hatch.
    nonisolated static func resolveStorageRoot() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        return container.appendingPathComponent("Documents/VCDR")
    }

    // MARK: - Sync state

    enum SyncState: Equatable {
        case idle
        case paused(reason: String)
    }

    private(set) var syncState: SyncState = .idle

    // MARK: - Composition

    /// All disk I/O, scanning, and snapshot/tombstone writes flow through the
    /// inner store. We only layer on sync-aware behavior.
    let inner: FileSubstitutionStore

    private let metadataQuery: NSMetadataQuery
    private var queryObserverTokens: [NSObjectProtocol] = []
    private var accountObserverToken: (any NSObjectProtocol)?

    /// De-duplicates overlapping refreshes triggered by back-to-back metadata
    /// notifications.
    private var refreshInFlight = false

    /// Snapshot of per-item metadata facts captured on the main actor
    /// (`NSMetadataItem` attribute reads must run on the query's queue) and then
    /// shipped to a detached task for the blocking iCloud work.
    private struct MetadataSnapshot: Sendable {
        let toDownload: [URL]
        let conflicts: [URL]
    }

    /// Sendable payload produced off the main actor by `loadSnapshot`. Carries
    /// the inner file-store snapshot plus the account-token read so
    /// `init(snapshot:)` never touches the filesystem or iCloud.
    struct Snapshot: Sendable {
        let file: FileSubstitutionStore.Snapshot
        let hasUbiquityIdentity: Bool
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Starts the metadata query and
    /// account observer (cheap, MainActor-bound) but performs no scan, decode,
    /// or `ubiquityIdentityToken` read.
    init(snapshot: Snapshot) {
        self.inner = FileSubstitutionStore(snapshot: snapshot.file)
        self.metadataQuery = NSMetadataQuery()
        if snapshot.hasUbiquityIdentity {
            self.syncState = .idle
        } else {
            self.syncState = .paused(reason: "iCloud signed out")
        }
        startWatchingContainer()
        observeAccountStateChanges()
    }

    /// Scans the ubiquity container, decodes substitutions, and reads the
    /// account token. Safe to call from any thread; pair with `init(snapshot:)`
    /// on the main actor.
    nonisolated static func loadSnapshot(storageRoot: URL) -> Snapshot {
        Snapshot(
            file: FileSubstitutionStore.loadSnapshot(storageRoot: storageRoot),
            hasUbiquityIdentity: FileManager.default.ubiquityIdentityToken != nil
        )
    }

    // NB: no deinit. NotificationCenter observer tokens are held in stored
    // properties; they deallocate with `self`. Every closure captures
    // `[weak self]`, so any notification that fires after deallocation no-ops.
    // The `NSMetadataQuery` instance is likewise only retained by this class.

    // MARK: - SubstitutionStore (delegation)

    var substitutions: [Substitution] { inner.substitutions }

    func upsert(_ substitution: Substitution) { inner.upsert(substitution) }

    func delete(_ substitution: Substitution) { inner.delete(substitution) }

    func reload() { inner.reload() }

    /// Applies any pending remote changes: kicks off placeholder downloads,
    /// resolves conflict siblings, then rescans the directory into
    /// `substitutions`. Heavy work runs on a detached utility task; the
    /// MainActor is held only for the cheap metadata snapshot and final publish.
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let snapshot = collectMetadataSnapshot()
        await Task.detached(priority: .utility) {
            Self.applyMetadataSnapshotOffMain(snapshot)
        }.value
        await inner.reloadAsync()

        if case .paused = syncState { return }
        syncState = .idle
    }

    // MARK: - NSMetadataQuery watcher

    private func startWatchingContainer() {
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Everything under the Substitutions folder, snapshot or tombstone.
        metadataQuery.predicate = NSPredicate(
            format: "%K LIKE[c] %@",
            NSMetadataItemFSNameKey,
            "*.json"
        )
        metadataQuery.valueListAttributes = [
            NSMetadataItemURLKey,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemHasUnresolvedConflictsKey
        ]

        let nc = NotificationCenter.default
        queryObserverTokens.append(nc.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        })
        queryObserverTokens.append(nc.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: metadataQuery, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        })

        metadataQuery.enableUpdates()
        metadataQuery.start()
    }

    /// Reads the current `NSMetadataQuery` results on the main actor —
    /// `NSMetadataItem` attribute access must happen on the query's queue — and
    /// packages the work into a Sendable snapshot that can then be applied from
    /// a detached task without touching any Objective-C state.
    private func collectMetadataSnapshot() -> MetadataSnapshot {
        let substitutionsPath = inner.substitutionsDir.path
        let items = (metadataQuery.results as? [NSMetadataItem]) ?? []
        var toDownload: [URL] = []
        var conflicts: [URL] = []

        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.path.contains(substitutionsPath) else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                toDownload.append(url)
            }
            if let hasConflict = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               hasConflict {
                conflicts.append(url)
            }
        }

        return MetadataSnapshot(toDownload: toDownload, conflicts: conflicts)
    }

    /// Applies the main-thread-collected snapshot: kicks off iCloud placeholder
    /// downloads and resolves any conflict siblings. Both operations can block
    /// on iCloud daemon IPC and must not run on the main actor.
    nonisolated private static func applyMetadataSnapshotOffMain(_ snapshot: MetadataSnapshot) {
        for url in snapshot.toDownload {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        if !snapshot.conflicts.isEmpty {
            SubstitutionConflictResolver.resolve(urls: snapshot.conflicts)
        }
    }

    // MARK: - Account-state observation

    private func observeAccountStateChanges() {
        accountObserverToken = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccountState() }
        }
    }

    private func refreshAccountState() {
        if FileManager.default.ubiquityIdentityToken != nil {
            if case .paused = syncState { syncState = .idle }
        } else {
            syncState = .paused(reason: "iCloud signed out")
        }
    }
}
