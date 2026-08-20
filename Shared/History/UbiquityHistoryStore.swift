import Foundation

/// iCloud Drive-backed history store. Composes over `FileHistoryStore`,
/// pointing it at the ubiquity container's `Documents/VCDR` directory.
///
/// Background sync is handled by the OS iCloud daemon. This store layers on:
///   * `NSMetadataQuery` watcher — picks up remote changes and triggers
///     placeholder downloads + UI refresh.
///   * LWW conflict resolution — when concurrent edits produce `NSFileVersion`
///     siblings, the one with the latest `Conversation.lastUpdated` wins.
///   * Account-state observation — surfaces `.paused` when the user signs
///     out of iCloud mid-session.
///
/// Construction uses a Sendable `Snapshot` loaded off the main actor — when
/// the ubiquity container is unavailable, callers fall back to a local-only
/// `FileHistoryStore` before ever reaching this type.
@MainActor
@Observable
final class UbiquityHistoryStore: HistoryStore {

    nonisolated static let containerIdentifier = "iCloud.glebglazov.vcdr"

    /// Resolves the root of the ubiquity container's `Documents/VCDR` folder,
    /// or nil if iCloud is unavailable to the process right now.
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
        /// New records were detected in the ubiquity container but not yet
        /// merged into `conversations` — user must tap the sync indicator or
        /// pull-to-refresh to apply them.
        case pendingUpdates
        case paused(reason: String)
    }

    private(set) var syncState: SyncState = .idle

    // MARK: - Composition

    /// All disk I/O, indexing, pagination, and record/tombstone writes flow
    /// through the inner store. We only layer on sync-aware behavior.
    let inner: FileHistoryStore

    private let metadataQuery: NSMetadataQuery
    private var queryObserverTokens: [NSObjectProtocol] = []
    private var accountObserverToken: (any NSObjectProtocol)?

    /// Tracks whether the metadata query has delivered its initial
    /// `DidFinishGathering` event. Before that, updates are applied
    /// immediately so the first view of the page isn't empty. After that,
    /// updates surface as `.pendingUpdates` and wait for the user.
    private var hasGatheredInitialSet = false

    /// De-duplicates overlapping refreshes. A pull-to-refresh that arrives
    /// while an NSMetadataQuery-driven refresh is still running would
    /// otherwise double up on the directory scan and re-enter
    /// `rebuildIndexAndReloadFirstPageAsync` before the first pass publishes.
    private var refreshInFlight = false

    /// Snapshot of per-item metadata facts captured on the main actor
    /// (NSMetadataItem attribute reads must run on the query's queue) and
    /// then shipped to a detached task for the blocking iCloud work.
    private struct MetadataSnapshot: Sendable {
        let toDownload: [URL]
        let conflicts: [URL]
        let newFilenames: [String]
    }

    /// Sendable payload produced off the main actor by `loadSnapshot`. Carries
    /// the inner file-store snapshot plus the account-token read so
    /// `init(snapshot:)` never touches the filesystem or iCloud.
    struct Snapshot: Sendable {
        let file: FileHistoryStore.Snapshot
        let hasUbiquityIdentity: Bool
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Starts the metadata query and
    /// account observer (cheap, MainActor-bound) but performs no scan, decode,
    /// or `ubiquityIdentityToken` read.
    init(snapshot: Snapshot) {
        self.inner = FileHistoryStore(snapshot: snapshot.file)
        self.metadataQuery = NSMetadataQuery()
        if snapshot.hasUbiquityIdentity {
            self.syncState = .idle
        } else {
            self.syncState = .paused(reason: "iCloud signed out")
        }
        startWatchingContainer()
        observeAccountStateChanges()
    }

    /// Scans the ubiquity container, decodes the first page, and reads the
    /// account token. Safe to call from any thread; pair with `init(snapshot:)`
    /// on the main actor.
    nonisolated static func loadSnapshot(storageRoot: URL) -> Snapshot {
        Snapshot(
            file: FileHistoryStore.loadSnapshot(storageRoot: storageRoot),
            hasUbiquityIdentity: FileManager.default.ubiquityIdentityToken != nil
        )
    }

    // NB: no deinit. NotificationCenter observer tokens are held in stored
    // properties; they deallocate with `self`. Every closure captures
    // `[weak self]`, so any notification that fires after deallocation no-ops.
    // The `NSMetadataQuery` instance is likewise only retained by this class.

    // MARK: - HistoryStore (delegation)

    var conversations: [Conversation] { inner.conversations }
    var latestConversation: Conversation? { inner.latestConversation }
    var hasMorePages: Bool { inner.hasMorePages }

    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    ) {
        inner.record(
            conversationID: conversationID,
            inputSegments: inputSegments,
            output: output,
            label: label
        )
    }

    func removeConversation(_ conversation: Conversation) {
        inner.removeConversation(conversation)
    }

    func clearAll() { inner.clearAll() }

    func loadNextPage() { inner.loadNextPage() }

    /// Applies any pending remote updates: kicks off placeholder downloads,
    /// resolves conflict siblings, then rescans the filesystem and reloads
    /// the first page into `conversations`. Called when the user taps the
    /// sync indicator or pulls-to-refresh.
    ///
    /// Async because the heavy work (iCloud download requests, conflict
    /// resolution, directory scan, first-page decode) runs on a detached
    /// utility task. The MainActor is only held for the cheap NSMetadataItem
    /// snapshot and the final state publish — so the sheet's "Done" button
    /// stays responsive while a refresh is in flight.
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let snapshot = collectMetadataSnapshot()
        await Task.detached(priority: .utility) {
            Self.applyMetadataSnapshotOffMain(snapshot)
        }.value
        await inner.rebuildIndexAndReloadFirstPageAsync()

        if case .paused = syncState { return }
        syncState = .idle
    }

    // MARK: - NSMetadataQuery watcher

    private func startWatchingContainer() {
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Everything under the conversations folder, snapshot or tombstone.
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
            Task { @MainActor [weak self] in await self?.handleInitialGathering() }
        })
        queryObserverTokens.append(nc.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: metadataQuery, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleIncrementalUpdate() }
        })

        metadataQuery.enableUpdates()
        metadataQuery.start()
    }

    /// First-load path: apply immediately so the history page isn't empty
    /// on the user's first visit after enabling sync.
    private func handleInitialGathering() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let snapshot = collectMetadataSnapshot()
        await Task.detached(priority: .utility) {
            Self.applyMetadataSnapshotOffMain(snapshot)
        }.value
        await inner.rebuildIndexAndReloadFirstPageAsync()
        hasGatheredInitialSet = true
        if case .paused = syncState { return }
        syncState = .idle
    }

    /// Subsequent-update path: detect newly-added filenames and surface them
    /// as `.pendingUpdates` so the user decides when to apply. Downloads
    /// are still kicked off in the background so the bytes are ready by
    /// the time the user taps refresh.
    private func handleIncrementalUpdate() async {
        guard hasGatheredInitialSet else {
            // Shouldn't happen — DidUpdate fires after DidFinishGathering —
            // but defensively: treat as initial.
            await handleInitialGathering()
            return
        }

        let snapshot = collectMetadataSnapshot()
        await Task.detached(priority: .utility) {
            Self.applyMetadataSnapshotOffMain(snapshot)
        }.value

        // Account state always wins.
        if case .paused = syncState { return }
        if !snapshot.newFilenames.isEmpty {
            syncState = .pendingUpdates
        }
    }

    /// Reads the current `NSMetadataQuery` results on the main actor —
    /// `NSMetadataItem` attribute access must happen on the query's queue —
    /// and packages the work into a Sendable snapshot that can then be
    /// applied from a detached task without touching any Objective-C state.
    private func collectMetadataSnapshot() -> MetadataSnapshot {
        let conversationsPath = inner.conversationsDir.path
        let items = (metadataQuery.results as? [NSMetadataItem]) ?? []
        let known = inner.indexedFilenames
        var toDownload: [URL] = []
        var conflicts: [URL] = []
        var newFilenames: [String] = []

        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.path.contains(conversationsPath) else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                toDownload.append(url)
            }
            if let hasConflict = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               hasConflict {
                conflicts.append(url)
            }
            let filename = url.lastPathComponent
            if !known.contains(filename) {
                newFilenames.append(filename)
            }
        }

        return MetadataSnapshot(
            toDownload: toDownload,
            conflicts: conflicts,
            newFilenames: newFilenames
        )
    }

    /// Applies the main-thread-collected snapshot: kicks off iCloud
    /// placeholder downloads and resolves any conflict siblings. Both
    /// operations can block on iCloud daemon IPC and must not run on the
    /// main actor.
    nonisolated private static func applyMetadataSnapshotOffMain(_ snapshot: MetadataSnapshot) {
        for url in snapshot.toDownload {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        if !snapshot.conflicts.isEmpty {
            HistoryConflictResolver.resolve(urls: snapshot.conflicts)
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
